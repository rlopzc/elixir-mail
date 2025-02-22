defmodule Mail.Parsers.RFC2822 do
  @moduledoc """
  RFC2822 Parser

  Will attempt to parse a valid RFC2822 message back into
  a `%Mail.Message{}` data model.

      Mail.Parsers.RFC2822.parse(message)
      %Mail.Message{body: "Some message", headers: %{to: ["user@example.com"], from: "other@example.com", subject: "Read this!"}}
  """

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @spec parse(binary() | nonempty_maybe_improper_list()) :: Mail.Message.t()
  def parse(content)

  def parse([_ | _] = lines) do
    [headers, lines] = extract_headers(lines)

    %Mail.Message{}
    |> parse_headers(headers)
    |> mark_multipart
    |> parse_body(lines)
  end

  def parse(content),
    do: content |> String.split(~r/(\r\n|\n)/) |> Enum.map(&String.trim_trailing/1) |> parse

  defp extract_headers(list, headers \\ [])

  defp extract_headers(["" | tail], headers),
    do: [Enum.reverse(headers), tail]

  defp extract_headers([<<" ", _::binary>> = folded_body | tail], [previous_header | headers]),
    do: extract_headers(tail, [previous_header <> folded_body | headers])

  defp extract_headers([<<"\t", _::binary>> = folded_body | tail], [previous_header | headers]),
    do: extract_headers(tail, [previous_header <> folded_body | headers])

  defp extract_headers([header | tail], headers),
    do: extract_headers(tail, [header | headers])

  @doc """
  Parses a RFC2822 timestamp to a DateTime with timezone

  [RFC2822 3.3 - Date and Time Specification](https://tools.ietf.org/html/rfc2822#section-3.3)
  """
  def to_datetime(<<" ", rest::binary>>), do: to_datetime(rest)
  def to_datetime(<<"\t", rest::binary>>), do: to_datetime(rest)
  def to_datetime(<<_day::binary-size(3), ", ", rest::binary>>), do: to_datetime(rest)

  def to_datetime(<<date::binary-size(1), " ", rest::binary>>),
    do: to_datetime("0" <> date <> " " <> rest)

  # This caters for an invalid date with no 0 before the hour, e.g. 5:21:43 instead of 05:21:43
  def to_datetime(<<date::binary-size(11), " ", hour::binary-size(1), ":", rest::binary>>) do
    to_datetime("#{date} 0#{hour}:#{rest}")
  end

  # This caters for an invalid date with dashes between the date/month/year parts
  def to_datetime(
        <<date::binary-size(2), "-", month::binary-size(3), "-", year::binary-size(4),
          rest::binary>>
      ) do
    to_datetime("#{date} #{month} #{year}#{rest}")
  end

  # This caters for an invalid two-digit year
  def to_datetime(
        <<date::binary-size(2), " ", month::binary-size(3), " ", year::binary-size(2), " ",
          rest::binary>>
      ) do
    year = year |> String.to_integer() |> to_four_digit_year()
    to_datetime("#{date} #{month} #{year} #{rest}")
  end

  # This caters for missing seconds
  def to_datetime(
        <<date::binary-size(11), " ", hour::binary-size(2), ":", minute::binary-size(2), " ",
          rest::binary>>
      ) do
    to_datetime("#{date} #{hour}:#{minute}:00 #{rest}")
  end

  # Fixes invalid value: Wed, 14 10 2015 12:34:17
  def to_datetime(
        <<date::binary-size(2), " ", month_digits::binary-size(2), " ", year::binary-size(4), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2),
          rest::binary>>
      ) do
    month_name = get_month_name(month_digits)
    to_datetime("#{date} #{month_name} #{year} #{hour}:#{minute}:#{second}#{rest}")
  end

  def to_datetime(
        <<date::binary-size(2), " ", month::binary-size(3), " ", year::binary-size(4), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), " ",
          time_zone::binary>>
      ) do
    year = year |> String.to_integer()
    month = get_month(String.downcase(month))
    date = date |> String.to_integer()

    hour = hour |> String.to_integer()
    minute = minute |> String.to_integer()
    second = second |> String.to_integer()

    time_zone = parse_time_zone(time_zone)

    date_string =
      "#{year}-#{date_pad(month)}-#{date_pad(date)}T#{date_pad(hour)}:#{date_pad(minute)}:#{date_pad(second)}#{time_zone}"

    {:ok, datetime, _offset} = DateTime.from_iso8601(date_string)
    datetime
  end

  # This adds support for a now obsolete format
  # https://tools.ietf.org/html/rfc2822#section-4.3
  def to_datetime(
        <<date::binary-size(2), " ", month::binary-size(3), " ", year::binary-size(4), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), " ",
          timezone::binary-size(3), _rest::binary>>
      ) do
    to_datetime("#{date} #{month} #{year} #{hour}:#{minute}:#{second} (#{timezone})")
  end

  # Fixes invalid value: Tue Aug 8 12:05:31 CAT 2017
  def to_datetime(
        <<_day::binary-size(3), " ", month::binary-size(3), " ", date::binary-size(2), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), " ",
          _tz::binary-size(3), " ", year::binary-size(4), _rest::binary>>
      ) do
    to_datetime("#{date} #{month} #{year} #{hour}:#{minute}:#{second}")
  end

  # Fixes invalid value with milliseconds Tue, 20 Jun 2017 09:44:58.568 +0000 (UTC)
  def to_datetime(
        <<date::binary-size(2), " ", month::binary-size(3), " ", year::binary-size(4), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), ".",
          _milliseconds::binary-size(3), rest::binary>>
      ) do
    to_datetime("#{date} #{month} #{year} #{hour}:#{minute}:#{second}#{rest}}")
  end

  # Fixes invalid value: Tue May 30 15:29:15 2017
  def to_datetime(
        <<_day::binary-size(3), " ", month::binary-size(3), " ", date::binary-size(2), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), " ",
          year::binary-size(4), _rest::binary>>
      ) do
    to_datetime("#{date} #{month} #{year} #{hour}:#{minute}:#{second} +0000")
  end

  # Fixes invalid value: Tue Aug 8 12:05:31 2017
  def to_datetime(
        <<_day::binary-size(3), " ", month::binary-size(3), " ", date::binary-size(1), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), " ",
          year::binary-size(4), _rest::binary>>
      ) do
    to_datetime("#{date} #{month} #{year} #{hour}:#{minute}:#{second} +0000")
  end

  # Fixes missing time zone
  def to_datetime(
        <<date::binary-size(2), " ", month::binary-size(3), " ", year::binary-size(4), " ",
          hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2)>>
      ) do
    to_datetime("#{date} #{month} #{year} #{hour}:#{minute}:#{second} +0000")
  end

  # # Fixes invalid value: Wed, 14 10 2015 12:34:17
  # def to_datetime(
  #       <<date::binary-size(2), " ", month_digits::binary-size(2), " ", year::binary-size(4), " ",
  #         hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2),
  #         rest::binary>>
  #     ) do
  #   month_name = get_month_name(month_digits)
  #   to_datetime("#{date} #{month_name} #{year} #{hour}:#{minute}:#{second}#{rest}")
  # end

  defp to_four_digit_year(year) when year >= 0 and year < 50, do: 2000 + year
  defp to_four_digit_year(year) when year < 100 and year >= 50, do: 1900 + year

  defp date_pad(number) when number < 10, do: "0" <> Integer.to_string(number)
  defp date_pad(number), do: Integer.to_string(number)

  defp parse_time_zone(<<"(", time_zone::binary>>) do
    time_zone
    |> String.trim_trailing(")")
    |> parse_time_zone()
  end

  @months
  |> Enum.with_index(1)
  |> Enum.each(fn {month_name, month_number} ->
    defp get_month(unquote(month_name)), do: unquote(month_number)

    defp get_month_name(unquote(String.pad_leading(to_string(month_number), 2, "0"))),
      do: unquote(month_name)
  end)

  # Greenwich Mean Time
  defp parse_time_zone("GMT"), do: "+0000"
  # Universal Time
  defp parse_time_zone("UTC"), do: "+0000"
  defp parse_time_zone("UT"), do: "+0000"

  # US
  defp parse_time_zone("EDT"), do: "-0400"
  defp parse_time_zone("EST"), do: "-0500"
  defp parse_time_zone("CDT"), do: "-0500"
  defp parse_time_zone("CST"), do: "-0600"
  defp parse_time_zone("MDT"), do: "-0600"
  defp parse_time_zone("MST"), do: "-0700"
  defp parse_time_zone("PDT"), do: "-0700"
  defp parse_time_zone("PST"), do: "-0800"
  # Military A-Z
  defp parse_time_zone(<<_zone_letter::binary-size(1)>>), do: "-0000"

  defp parse_time_zone(<<"+", offset::binary-size(4), _rest::binary>>), do: "+#{offset}"
  defp parse_time_zone(<<"-", offset::binary-size(4), _rest::binary>>), do: "-#{offset}"

  defp parse_time_zone(time_zone) do
    time_zone
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
  end

  @doc """
  Retrieves the "name" and "address" parts from an email message recipient
  (To, CC, etc.). The following is an example of recipient value:

      Full Name <fullname@company.tld>, another@company.tld

  In this example, `Full Name` is the "name" part and `fullname@company.tld` is
  the "address" part. `another@company.tld` does not have a "name" part, only
  an "address" part.

  The return value is a mixed list of tuples and strings, which should be
  interpreted in the following way:
  - When the element is just a string, it represents the "address" part only
  - When the element is a tuple, the format is `{name, address}`. Both "name"
    and "address" are strings
  """
  @spec parse_recipient_value(value :: String.t()) ::
          [{String.t(), String.t()} | String.t()]
  def parse_recipient_value(value) do
    Regex.scan(~r/\s*("?)(.*?)\1\s*?<?([^<\s]+@[^\s>,]+)>?,?/, value)
    |> Enum.map(fn
      [_, _, "", address] -> address
      [_, _, name, address] -> {name, address}
    end)
  end

  defp parse_headers(message, []), do: message

  defp parse_headers(message, [header | tail]) do
    [name, body] = String.split(header, ":", parts: 2)
    key = String.downcase(name)
    decoded = parse_encoded_word(body)
    headers = put_header(message.headers, key, parse_header_value(name, decoded))
    message = %{message | headers: headers}
    parse_headers(message, tail)
  end

  defp put_header(headers, "received" = key, value),
    do: Map.update(headers, key, [value], &[value | &1])

  defp put_header(headers, key, value),
    do: Map.put(headers, key, value)

  defp mark_multipart(message),
    do: Map.put(message, :multipart, multipart?(message.headers))

  defp parse_header_value(key, " " <> value),
    do: parse_header_value(key, value)

  defp parse_header_value(key, "\r" <> value),
    do: parse_header_value(key, value)

  defp parse_header_value(key, "\n" <> value),
    do: parse_header_value(key, value)

  defp parse_header_value(key, "\t" <> value),
    do: parse_header_value(key, value)

  defp parse_header_value("To", value),
    do: parse_recipient_value(value)

  defp parse_header_value("CC", value),
    do: parse_recipient_value(value)

  defp parse_header_value("From", value),
    do:
      parse_recipient_value(value)
      |> List.first()

  defp parse_header_value("Reply-To", value),
    do:
      parse_recipient_value(value)
      |> List.first()

  defp parse_header_value("Date", timestamp),
    do: to_datetime(timestamp)

  defp parse_header_value("Received", value),
    do: parse_received_value(value)

  defp parse_header_value("Content-Type", value) do
    case parse_structured_header_value(value) do
      [_ | _] = header -> header
      <<value::binary>> -> [value, {"charset", "us-ascii"}]
    end
  end

  defp parse_header_value("Content-Disposition", value),
    do: parse_structured_header_value(value)

  defp parse_header_value(_key, value),
    do: value

  # See https://tools.ietf.org/html/rfc2047
  defp parse_encoded_word(""), do: ""

  defp parse_encoded_word(<<"=?", value::binary>>) do
    case String.split(value, "?", parts: 4) do
      [_charset, encoding, encoded_string, <<"=", remainder::binary>>] ->
        decoded_string =
          case String.upcase(encoding) do
            "Q" ->
              Mail.Encoders.QuotedPrintable.decode(encoded_string)

            "B" ->
              Mail.Encoders.Base64.decode(encoded_string)
          end

        decoded_string <> parse_encoded_word(remainder)

      _ ->
        # Not an encoded word, moving on
        "=?" <> parse_encoded_word(value)
    end
  end

  defp parse_encoded_word(<<char::utf8, rest::binary>>),
    do: <<char::utf8, parse_encoded_word(rest)::binary>>

  defp parse_structured_header_value(string, value \\ nil, sub_types \\ [], acc \\ "")

  defp parse_structured_header_value("", value, [{key, nil} | sub_types], acc),
    do: [value | Enum.reverse([{key, acc} | sub_types])]

  defp parse_structured_header_value("", nil, [], acc),
    do: acc

  defp parse_structured_header_value("", value, sub_types, ""),
    do: [value | Enum.reverse(sub_types)]

  defp parse_structured_header_value("", value, [], acc),
    do: [value, String.trim(acc)]

  defp parse_structured_header_value("", value, sub_types, acc),
    do: parse_structured_header_value("", value, sub_types, String.trim(acc))

  defp parse_structured_header_value(<<"\"", rest::binary>>, value, sub_types, acc) do
    {string, rest} = parse_quoted_string(rest)
    parse_structured_header_value(rest, value, sub_types, <<acc::binary, string::binary>>)
  end

  defp parse_structured_header_value(<<";", rest::binary>>, nil, sub_types, acc),
    do: parse_structured_header_value(rest, acc, sub_types, "")

  defp parse_structured_header_value(<<";", rest::binary>>, value, [{key, nil} | sub_types], acc),
    do: parse_structured_header_value(rest, value, [{key, acc} | sub_types], "")

  defp parse_structured_header_value(<<"=", rest::binary>>, value, sub_types, acc),
    do: parse_structured_header_value(rest, value, [{key_to_atom(acc), nil} | sub_types], "")

  defp parse_structured_header_value(<<char::utf8, rest::binary>>, value, sub_types, acc),
    do: parse_structured_header_value(rest, value, sub_types, <<acc::binary, char::utf8>>)

  defp parse_quoted_string(string, acc \\ "")

  defp parse_quoted_string(<<"\\", char::utf8, rest::binary>>, acc),
    do: parse_quoted_string(rest, <<acc::binary, char::utf8>>)

  defp parse_quoted_string(<<"\"", rest::binary>>, acc), do: {acc, rest}

  defp parse_quoted_string(<<char::utf8, rest::binary>>, acc),
    do: parse_quoted_string(rest, <<acc::binary, char::utf8>>)

  defp parse_received_value(value) do
    case String.split(value, ";") do
      [value, ""] ->
        [value]

      [value, date] ->
        {value, date} =
          case extract_comment(remove_timezone_comment(date)) do
            {date, nil} -> {value, date}
            {date, comment} -> {"#{value} #{comment}", date}
          end

        [value, {"date", to_datetime(remove_excess_whitespace(date))}]

      value ->
        value
    end
  end

  defp remove_timezone_comment(date_string) do
    string_size = date_string |> String.trim_trailing() |> byte_size()

    if string_size > 6 do
      case binary_part(date_string, string_size - 6, 6) do
        <<" (", _::binary-size(3), ")">> -> binary_part(date_string, 0, string_size - 6)
        _ -> date_string
      end
    else
      date_string
    end
  end

  defp extract_comment(string, state \\ :value, value \\ "", comment \\ nil)
  defp extract_comment("", _, value, comment), do: {value, comment}

  defp extract_comment(<<"(", rest::binary>>, :value, value, nil),
    do: extract_comment(rest, :comment, value, "(")

  defp extract_comment(<<")", rest::binary>>, :comment, value, comment),
    do: extract_comment(rest, :value, value, comment <> ")")

  defp extract_comment(<<char::utf8, rest::binary>>, :value, value, comment),
    do: extract_comment(rest, :value, <<value::binary, char::utf8>>, comment)

  defp extract_comment(<<char::utf8, rest::binary>>, :comment, value, comment),
    do: extract_comment(rest, :comment, value, <<comment::binary, char::utf8>>)

  defp remove_excess_whitespace(<<>>), do: <<>>

  defp remove_excess_whitespace(<<"  ", rest::binary>>),
    do: remove_excess_whitespace(<<" ", rest::binary>>)

  defp remove_excess_whitespace(<<"\t", rest::binary>>),
    do: remove_excess_whitespace(<<" ", rest::binary>>)

  defp remove_excess_whitespace(<<char::utf8, rest::binary>>),
    do: <<char::utf8, remove_excess_whitespace(rest)::binary>>

  defp parse_body(%Mail.Message{multipart: true} = message, lines) do
    content_type = message.headers["content-type"]
    boundary = Mail.Proplist.get(content_type, "boundary")

    parts =
      lines
      |> extract_parts(boundary)
      |> Enum.map(fn part ->
        parse(part)
      end)

    Map.put(message, :parts, parts)
  end

  defp parse_body(%Mail.Message{} = message, []) do
    message
  end

  defp parse_body(%Mail.Message{} = message, lines) do
    decoded =
      lines
      |> join_body
      |> decode(message)

    Map.put(message, :body, decoded)
  end

  defp join_body(lines, acc \\ [])
  defp join_body([], acc), do: acc |> Enum.reverse() |> Enum.join("\r\n")
  defp join_body([""], acc), do: acc |> Enum.reverse() |> Enum.join("\r\n")
  defp join_body([head | tail], acc), do: join_body(tail, [head | acc])

  defp extract_parts(lines, boundary, acc \\ [], parts \\ nil)

  defp extract_parts([], _boundary, _acc, parts),
    do: Enum.reverse(List.wrap(parts))

  defp extract_parts(["--" <> boundary | tail], boundary, acc, nil),
    do: extract_parts(tail, boundary, acc, [])

  defp extract_parts(["--" <> boundary | tail], boundary, acc, parts),
    do: extract_parts(tail, boundary, [], [Enum.reverse(acc) | parts])

  defp extract_parts([<<"--" <> rest>> = line | tail], boundary, acc, parts) do
    if rest == boundary <> "--" do
      extract_parts([], boundary, [], [Enum.reverse(acc) | parts])
    else
      extract_parts(tail, boundary, [line | acc], parts)
    end
  end

  defp extract_parts([_line | tail], boundary, acc, nil),
    do: extract_parts(tail, boundary, acc, nil)

  defp extract_parts([head | tail], boundary, acc, parts),
    do: extract_parts(tail, boundary, [head | acc], parts)

  defp key_to_atom(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp multipart?(headers) do
    content_type = headers["content-type"]

    !!case content_type do
      nil -> nil
      type when is_binary(type) -> nil
      content_type -> Mail.Proplist.get(content_type, "boundary")
    end
  end

  defp decode(body, message) do
    body = String.trim_trailing(body)
    transfer_encoding = Mail.Message.get_header(message, "content-transfer-encoding")
    Mail.Encoder.decode(body, transfer_encoding)
  end
end

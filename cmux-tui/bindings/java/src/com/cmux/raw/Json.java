package com.cmux.raw;

import java.lang.reflect.Array;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Small dependency-free JSON codec used by the Unix socket transport.
 *
 * <p>Integral values are decoded as {@link Long} when they fit and
 * {@link BigInteger} otherwise. This is important for cmux's uint64 values.
 */
public final class Json {
    public static final int DEFAULT_MAX_DEPTH = 128;

    private Json() {}

    public static Object parse(String text) {
        return parse(text, DEFAULT_MAX_DEPTH);
    }

    public static Object parse(String text, int maxDepth) {
        if (text == null) {
            throw new NullPointerException("text");
        }
        requireDepth(maxDepth);
        Parser parser = new Parser(text, maxDepth);
        Object value = parser.parseValue(0);
        parser.skipWhitespace();
        if (!parser.isEnd()) {
            throw new JsonException("trailing input at character " + parser.index);
        }
        return value;
    }

    public static Object parse(byte[] utf8, int maxDepth) {
        try {
            String text = StandardCharsets.UTF_8
                .newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(utf8))
                .toString();
            return parse(text, maxDepth);
        } catch (CharacterCodingException error) {
            throw new JsonException("invalid UTF-8 JSON", error);
        }
    }

    public static String stringify(Object value) {
        return stringify(value, DEFAULT_MAX_DEPTH);
    }

    public static String stringify(Object value, int maxDepth) {
        requireDepth(maxDepth);
        StringBuilder out = new StringBuilder();
        write(value, out, 0, maxDepth);
        return out.toString();
    }

    private static void requireDepth(int maxDepth) {
        if (maxDepth < 1) {
            throw new IllegalArgumentException("maxDepth must be positive");
        }
    }

    private static void write(Object value, StringBuilder out, int depth, int maxDepth) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String text) {
            writeString(text, out);
        } else if (value instanceof UInt64 unsigned) {
            out.append(unsigned);
        } else if (value instanceof BigInteger || value instanceof Byte || value instanceof Short
                || value instanceof Integer || value instanceof Long) {
            out.append(value);
        } else if (value instanceof BigDecimal decimal) {
            out.append(decimal.toString());
        } else if (value instanceof Double doubleValue) {
            if (!Double.isFinite(doubleValue)) {
                throw new JsonException("non-finite JSON number");
            }
            out.append(doubleValue);
        } else if (value instanceof Float floatValue) {
            if (!Float.isFinite(floatValue)) {
                throw new JsonException("non-finite JSON number");
            }
            out.append(floatValue);
        } else if (value instanceof Number) {
            throw new JsonException("unsupported JSON number: " + value.getClass().getName());
        } else if (value instanceof Boolean) {
            out.append(value);
        } else if (value instanceof Map<?, ?> map) {
            requireContainerDepth(depth, maxDepth);
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!(entry.getKey() instanceof String key)) {
                    throw new JsonException("object keys must be strings");
                }
                if (!first) {
                    out.append(',');
                }
                first = false;
                writeString(key, out);
                out.append(':');
                write(entry.getValue(), out, depth + 1, maxDepth);
            }
            out.append('}');
        } else if (value instanceof Iterable<?> items) {
            requireContainerDepth(depth, maxDepth);
            out.append('[');
            boolean first = true;
            for (Object item : items) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                write(item, out, depth + 1, maxDepth);
            }
            out.append(']');
        } else if (value.getClass().isArray()) {
            requireContainerDepth(depth, maxDepth);
            out.append('[');
            int length = Array.getLength(value);
            for (int i = 0; i < length; i++) {
                if (i > 0) {
                    out.append(',');
                }
                write(Array.get(value, i), out, depth + 1, maxDepth);
            }
            out.append(']');
        } else {
            throw new JsonException("unsupported JSON value: " + value.getClass().getName());
        }
    }

    private static void requireContainerDepth(int depth, int maxDepth) {
        if (depth >= maxDepth) {
            throw new JsonException("JSON nesting exceeds " + maxDepth);
        }
    }

    private static void writeString(String value, StringBuilder out) {
        out.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 0x20) {
                        appendUnicodeEscape(c, out);
                    } else if (Character.isHighSurrogate(c)) {
                        if (i + 1 >= value.length() || !Character.isLowSurrogate(value.charAt(i + 1))) {
                            throw new JsonException("unpaired high surrogate in string");
                        }
                        out.append(c).append(value.charAt(++i));
                    } else if (Character.isLowSurrogate(c)) {
                        throw new JsonException("unpaired low surrogate in string");
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }

    private static void appendUnicodeEscape(char value, StringBuilder out) {
        String hex = Integer.toHexString(value);
        out.append("\\u");
        out.append("0".repeat(4 - hex.length()));
        out.append(hex);
    }

    private static final class Parser {
        private final String text;
        private final int maxDepth;
        private int index;

        Parser(String text, int maxDepth) {
            this.text = text;
            this.maxDepth = maxDepth;
        }

        boolean isEnd() {
            return index >= text.length();
        }

        void skipWhitespace() {
            while (!isEnd()) {
                char c = text.charAt(index);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
                    index++;
                } else {
                    break;
                }
            }
        }

        Object parseValue(int depth) {
            skipWhitespace();
            if (isEnd()) {
                throw new JsonException("unexpected end of input");
            }
            return switch (text.charAt(index)) {
                case '{' -> parseObject(depth);
                case '[' -> parseArray(depth);
                case '"' -> parseString();
                case 't' -> literal("true", Boolean.TRUE);
                case 'f' -> literal("false", Boolean.FALSE);
                case 'n' -> literal("null", null);
                default -> parseNumber();
            };
        }

        private Map<String, Object> parseObject(int depth) {
            requireContainerDepth(depth, maxDepth);
            index++;
            LinkedHashMap<String, Object> object = new LinkedHashMap<>();
            skipWhitespace();
            if (consume('}')) {
                return object;
            }
            while (true) {
                skipWhitespace();
                if (isEnd() || text.charAt(index) != '"') {
                    throw new JsonException("expected object key at character " + index);
                }
                String key = parseString();
                skipWhitespace();
                expect(':');
                Object value = parseValue(depth + 1);
                if (object.containsKey(key)) {
                    throw new JsonException("duplicate object key " + key);
                }
                object.put(key, value);
                skipWhitespace();
                if (consume('}')) {
                    return object;
                }
                expect(',');
            }
        }

        private List<Object> parseArray(int depth) {
            requireContainerDepth(depth, maxDepth);
            index++;
            ArrayList<Object> array = new ArrayList<>();
            skipWhitespace();
            if (consume(']')) {
                return array;
            }
            while (true) {
                array.add(parseValue(depth + 1));
                skipWhitespace();
                if (consume(']')) {
                    return array;
                }
                expect(',');
            }
        }

        private String parseString() {
            expect('"');
            StringBuilder out = new StringBuilder();
            while (!isEnd()) {
                char c = text.charAt(index++);
                if (c == '"') {
                    return out.toString();
                }
                if (c == '\\') {
                    if (isEnd()) {
                        throw new JsonException("unterminated escape");
                    }
                    char escaped = text.charAt(index++);
                    switch (escaped) {
                        case '"', '\\', '/' -> out.append(escaped);
                        case 'b' -> out.append('\b');
                        case 'f' -> out.append('\f');
                        case 'n' -> out.append('\n');
                        case 'r' -> out.append('\r');
                        case 't' -> out.append('\t');
                        case 'u' -> appendUnicode(out);
                        default -> throw new JsonException(
                            "bad escape \\" + escaped + " at character " + (index - 1)
                        );
                    }
                } else {
                    if (c < 0x20) {
                        throw new JsonException("control character in string at character " + (index - 1));
                    }
                    if (Character.isHighSurrogate(c)) {
                        if (isEnd() || !Character.isLowSurrogate(text.charAt(index))) {
                            throw new JsonException("unpaired high surrogate in string");
                        }
                        out.append(c).append(text.charAt(index++));
                    } else if (Character.isLowSurrogate(c)) {
                        throw new JsonException("unpaired low surrogate in string");
                    } else {
                        out.append(c);
                    }
                }
            }
            throw new JsonException("unterminated string");
        }

        private void appendUnicode(StringBuilder out) {
            int code = readHex4();
            if (Character.isHighSurrogate((char) code)) {
                if (index + 2 > text.length() || text.charAt(index) != '\\' || text.charAt(index + 1) != 'u') {
                    throw new JsonException("missing low surrogate");
                }
                index += 2;
                int low = readHex4();
                if (!Character.isLowSurrogate((char) low)) {
                    throw new JsonException("invalid low surrogate");
                }
                out.append(Character.toChars(Character.toCodePoint((char) code, (char) low)));
            } else if (Character.isLowSurrogate((char) code)) {
                throw new JsonException("unpaired low surrogate");
            } else {
                out.append((char) code);
            }
        }

        private int readHex4() {
            if (index + 4 > text.length()) {
                throw new JsonException("short unicode escape");
            }
            int value = 0;
            for (int i = 0; i < 4; i++) {
                int digit = asciiHexDigit(text.charAt(index++));
                if (digit < 0) {
                    throw new JsonException("bad unicode escape");
                }
                value = (value << 4) | digit;
            }
            return value;
        }

        private Object parseNumber() {
            int start = index;
            if (consume('-') && isEnd()) {
                throw new JsonException("bad number");
            }
            if (consume('0')) {
                if (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    throw new JsonException("leading zero in number");
                }
            } else {
                if (isEnd() || !isAsciiDigit(text.charAt(index))) {
                    throw new JsonException("expected JSON value at character " + index);
                }
                while (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    index++;
                }
            }
            boolean decimal = false;
            if (consume('.')) {
                decimal = true;
                requireDigit();
                while (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    index++;
                }
            }
            if (!isEnd() && (text.charAt(index) == 'e' || text.charAt(index) == 'E')) {
                decimal = true;
                index++;
                if (!isEnd() && (text.charAt(index) == '+' || text.charAt(index) == '-')) {
                    index++;
                }
                requireDigit();
                while (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    index++;
                }
            }
            String raw = text.substring(start, index);
            try {
                if (decimal) {
                    return new BigDecimal(raw);
                }
                BigInteger integer = new BigInteger(raw);
                if (integer.bitLength() < 64) {
                    return integer.longValue();
                }
                return integer;
            } catch (NumberFormatException error) {
                throw new JsonException("bad number " + raw, error);
            }
        }

        private void requireDigit() {
            if (isEnd() || !isAsciiDigit(text.charAt(index))) {
                throw new JsonException("expected digit at character " + index);
            }
        }

        private static boolean isAsciiDigit(char c) {
            return c >= '0' && c <= '9';
        }

        private static int asciiHexDigit(char c) {
            if (c >= '0' && c <= '9') {
                return c - '0';
            }
            if (c >= 'a' && c <= 'f') {
                return 10 + c - 'a';
            }
            if (c >= 'A' && c <= 'F') {
                return 10 + c - 'A';
            }
            return -1;
        }

        private Object literal(String literal, Object value) {
            if (!text.startsWith(literal, index)) {
                throw new JsonException("expected " + literal + " at character " + index);
            }
            index += literal.length();
            return value;
        }

        private boolean consume(char c) {
            if (!isEnd() && text.charAt(index) == c) {
                index++;
                return true;
            }
            return false;
        }

        private void expect(char c) {
            if (!consume(c)) {
                throw new JsonException("expected '" + c + "' at character " + index);
            }
        }
    }
}

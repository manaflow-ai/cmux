package com.cmux.conformance;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Small adapter-local JSON codec, used because Java 17 has no standard JSON API. */
final class MiniJson {
    private MiniJson() {}

    static Object parse(String input) {
        Parser parser = new Parser(input);
        Object value = parser.value();
        parser.space();
        if (!parser.done()) {
            throw new IllegalArgumentException("trailing JSON at byte " + parser.offset);
        }
        return value;
    }

    static String stringify(Object value) {
        StringBuilder output = new StringBuilder();
        write(output, value);
        return output.toString();
    }

    private static void write(StringBuilder output, Object value) {
        if (value == null) {
            output.append("null");
        } else if (value instanceof String string) {
            string(output, string);
        } else if (value instanceof Boolean || value instanceof Number) {
            output.append(value);
        } else if (value instanceof Map<?, ?> map) {
            output.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!(entry.getKey() instanceof String key)) {
                    throw new IllegalArgumentException("JSON object key is not a string");
                }
                if (!first) {
                    output.append(',');
                }
                first = false;
                string(output, key);
                output.append(':');
                write(output, entry.getValue());
            }
            output.append('}');
        } else if (value instanceof Iterable<?> values) {
            output.append('[');
            boolean first = true;
            for (Object item : values) {
                if (!first) {
                    output.append(',');
                }
                first = false;
                write(output, item);
            }
            output.append(']');
        } else {
            throw new IllegalArgumentException(
                "cannot encode JSON value " + value.getClass().getName()
            );
        }
    }

    private static void string(StringBuilder output, String value) {
        output.append('"');
        for (int offset = 0; offset < value.length();) {
            int codePoint = value.codePointAt(offset);
            offset += Character.charCount(codePoint);
            switch (codePoint) {
                case '"' -> output.append("\\\"");
                case '\\' -> output.append("\\\\");
                case '\b' -> output.append("\\b");
                case '\f' -> output.append("\\f");
                case '\n' -> output.append("\\n");
                case '\r' -> output.append("\\r");
                case '\t' -> output.append("\\t");
                default -> {
                    if (codePoint < 0x20) {
                        output.append(String.format("\\u%04x", codePoint));
                    } else {
                        output.appendCodePoint(codePoint);
                    }
                }
            }
        }
        output.append('"');
    }

    private static final class Parser {
        private final String input;
        private int offset;

        Parser(String input) {
            this.input = input;
        }

        boolean done() {
            return offset == input.length();
        }

        void space() {
            while (!done() && Character.isWhitespace(input.charAt(offset))) {
                offset++;
            }
        }

        Object value() {
            space();
            if (done()) {
                throw failure("expected JSON value");
            }
            return switch (input.charAt(offset)) {
                case '{' -> object();
                case '[' -> array();
                case '"' -> string();
                case 't' -> literal("true", Boolean.TRUE);
                case 'f' -> literal("false", Boolean.FALSE);
                case 'n' -> literal("null", null);
                default -> number();
            };
        }

        Map<String, Object> object() {
            expect('{');
            LinkedHashMap<String, Object> result = new LinkedHashMap<>();
            space();
            if (take('}')) {
                return result;
            }
            while (true) {
                space();
                if (done() || input.charAt(offset) != '"') {
                    throw failure("expected object key");
                }
                String key = string();
                space();
                expect(':');
                if (result.putIfAbsent(key, value()) != null) {
                    throw failure("duplicate object key " + key);
                }
                space();
                if (take('}')) {
                    return result;
                }
                expect(',');
            }
        }

        List<Object> array() {
            expect('[');
            ArrayList<Object> result = new ArrayList<>();
            space();
            if (take(']')) {
                return result;
            }
            while (true) {
                result.add(value());
                space();
                if (take(']')) {
                    return result;
                }
                expect(',');
            }
        }

        String string() {
            expect('"');
            StringBuilder result = new StringBuilder();
            while (!done()) {
                char value = input.charAt(offset++);
                if (value == '"') {
                    return result.toString();
                }
                if (value == '\\') {
                    if (done()) {
                        throw failure("truncated escape");
                    }
                    char escape = input.charAt(offset++);
                    switch (escape) {
                        case '"' -> result.append('"');
                        case '\\' -> result.append('\\');
                        case '/' -> result.append('/');
                        case 'b' -> result.append('\b');
                        case 'f' -> result.append('\f');
                        case 'n' -> result.append('\n');
                        case 'r' -> result.append('\r');
                        case 't' -> result.append('\t');
                        case 'u' -> result.appendCodePoint(unicode());
                        default -> throw failure("invalid escape");
                    }
                } else {
                    if (value < 0x20) {
                        throw failure("unescaped control character");
                    }
                    result.append(value);
                }
            }
            throw failure("unterminated string");
        }

        int unicode() {
            if (offset + 4 > input.length()) {
                throw failure("truncated Unicode escape");
            }
            int value;
            try {
                value = Integer.parseInt(input.substring(offset, offset + 4), 16);
            } catch (NumberFormatException error) {
                throw failure("invalid Unicode escape");
            }
            offset += 4;
            return value;
        }

        Object literal(String encoded, Object value) {
            if (!input.startsWith(encoded, offset)) {
                throw failure("invalid literal");
            }
            offset += encoded.length();
            return value;
        }

        BigDecimal number() {
            int start = offset;
            if (take('-')) {
                // Sign consumed.
            }
            if (take('0')) {
                // A zero integer has no following digits.
            } else {
                digits();
            }
            if (take('.')) {
                digits();
            }
            if (take('e') || take('E')) {
                take('+');
                take('-');
                digits();
            }
            try {
                return new BigDecimal(input.substring(start, offset));
            } catch (NumberFormatException error) {
                throw failure("invalid number");
            }
        }

        void digits() {
            int start = offset;
            while (!done() && Character.isDigit(input.charAt(offset))) {
                offset++;
            }
            if (offset == start) {
                throw failure("expected digit");
            }
        }

        boolean take(char expected) {
            if (!done() && input.charAt(offset) == expected) {
                offset++;
                return true;
            }
            return false;
        }

        void expect(char expected) {
            if (!take(expected)) {
                throw failure("expected " + expected);
            }
        }

        IllegalArgumentException failure(String message) {
            return new IllegalArgumentException(message + " at byte " + offset);
        }
    }
}

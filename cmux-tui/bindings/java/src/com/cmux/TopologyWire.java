package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.UUID;

final class TopologyWire {
    private TopologyWire() {}

    @SuppressWarnings("unchecked")
    static Map<String, Object> object(Object value, String label) {
        if (!(value instanceof Map<?, ?>)) {
            throw new IllegalArgumentException(label + " is not an object");
        }
        return (Map<String, Object>) value;
    }

    @SuppressWarnings("unchecked")
    static List<Object> list(Object value, String label) {
        if (!(value instanceof List<?>)) {
            throw new IllegalArgumentException(label + " is not an array");
        }
        return (List<Object>) value;
    }

    static long uint(Object value) {
        long result = CmuxClient.asLong(value);
        if (result < 0) throw new IllegalArgumentException("expected non-negative integer");
        return result;
    }

    static double number(Object value) {
        if (!(value instanceof Number number) || !Double.isFinite(number.doubleValue())) {
            throw new IllegalArgumentException("expected finite number");
        }
        return number.doubleValue();
    }

    static String string(Object value) {
        if (!(value instanceof String string)) throw new IllegalArgumentException("expected string");
        return string;
    }

    static String nullableString(Object value) {
        return value == null ? null : string(value);
    }

    static UUID uuid(Object value) {
        String encoded = string(value);
        UUID parsed = UUID.fromString(encoded);
        if (!parsed.toString().equals(encoded)) {
            throw new IllegalArgumentException("UUID must use lowercase hyphenated form");
        }
        return parsed;
    }
}

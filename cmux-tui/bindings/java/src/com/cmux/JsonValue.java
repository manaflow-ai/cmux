package com.cmux;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * An explicitly untyped JSON value used only at catalog extension points.
 *
 * <p>The wrapped value is recursively immutable and limited to JSON-compatible
 * null, boolean, number, string, array, and string-keyed object values.</p>
 */
public final class JsonValue {
    private final Object value;

    private JsonValue(Object value) {
        this.value = freeze(value, "JSON value");
    }

    public static JsonValue of(Object value) {
        return new JsonValue(value);
    }

    public Object value() {
        return value;
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof JsonValue json && Objects.equals(value, json.value);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(value);
    }

    @Override
    public String toString() {
        return String.valueOf(value);
    }

    private static Object freeze(Object value, String context) {
        if (value == null || value instanceof Boolean || value instanceof String ||
                value instanceof Byte || value instanceof Short ||
                value instanceof Integer || value instanceof Long ||
                value instanceof BigInteger || value instanceof BigDecimal) {
            return value;
        }
        if (value instanceof Float number) {
            if (!Float.isFinite(number)) {
                throw new IllegalArgumentException(context + " number must be finite");
            }
            return number;
        }
        if (value instanceof Double number) {
            if (!Double.isFinite(number)) {
                throw new IllegalArgumentException(context + " number must be finite");
            }
            return number;
        }
        if (value instanceof Number number) {
            try {
                return new BigDecimal(number.toString());
            } catch (NumberFormatException error) {
                throw new IllegalArgumentException(
                    context + " has an unsupported number",
                    error
                );
            }
        }
        if (value instanceof List<?> list) {
            List<Object> copy = new ArrayList<>(list.size());
            for (Object item : list) {
                copy.add(freeze(item, context + " array item"));
            }
            return Collections.unmodifiableList(copy);
        }
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> copy = new LinkedHashMap<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!(entry.getKey() instanceof String key)) {
                    throw new IllegalArgumentException(
                        context + " object keys must be strings"
                    );
                }
                copy.put(key, freeze(entry.getValue(), context + "." + key));
            }
            return Collections.unmodifiableMap(copy);
        }
        throw new IllegalArgumentException(
            context + " contains unsupported " + value.getClass().getName()
        );
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> immutableObject(
        Map<String, Object> value,
        String context
    ) {
        Objects.requireNonNull(value, context);
        return (Map<String, Object>) freeze(value, context);
    }
}

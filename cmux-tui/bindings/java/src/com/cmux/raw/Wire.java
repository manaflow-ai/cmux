package com.cmux.raw;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Function;

/** Decode and immutable-copy helpers used by generated protocol models. */
public final class Wire {
    private Wire() {}

    @SuppressWarnings("unchecked")
    public static Map<String, Object> object(Object value, String context) {
        if (!(value instanceof Map<?, ?> raw)) {
            throw decode(context + " must be an object");
        }
        for (Object key : raw.keySet()) {
            if (!(key instanceof String)) {
                throw decode(context + " has a non-string key");
            }
        }
        return (Map<String, Object>) raw;
    }

    public static Object required(Map<String, Object> object, String name, String... aliases) {
        if (object.containsKey(name)) {
            return object.get(name);
        }
        for (String alias : aliases) {
            if (object.containsKey(alias)) {
                return object.get(alias);
            }
        }
        throw decode("missing required field " + name);
    }

    public static Object optional(Map<String, Object> object, String name, String... aliases) {
        if (object.containsKey(name)) {
            return object.get(name);
        }
        for (String alias : aliases) {
            if (object.containsKey(alias)) {
                return object.get(alias);
            }
        }
        return Missing.VALUE;
    }

    public static boolean isMissing(Object value) {
        return value == Missing.VALUE;
    }

    public static String string(Object value, String context) {
        if (value instanceof String text) {
            return text;
        }
        throw decode(context + " must be a string");
    }

    public static boolean bool(Object value, String context) {
        if (value instanceof Boolean bool) {
            return bool;
        }
        throw decode(context + " must be a boolean");
    }

    public static int uint8(Object value, String context) {
        return boundedInt(value, 0xffL, context);
    }

    public static int uint16(Object value, String context) {
        return boundedInt(value, 0xffffL, context);
    }

    public static long uint32(Object value, String context) {
        BigInteger integer = integer(value, context);
        if (integer.signum() < 0 || integer.bitLength() > 32) {
            throw decode(context + " is outside uint32");
        }
        return integer.longValue();
    }

    public static UInt64 uint64(Object value, String context) {
        try {
            if (value instanceof UInt64 unsigned) {
                return unsigned;
            }
            if (value instanceof BigInteger integer) {
                return UInt64.of(integer);
            }
            if (value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long) {
                return UInt64.of(((Number) value).longValue());
            }
            if (value instanceof String text) {
                return UInt64.parse(text);
            }
        } catch (IllegalArgumentException error) {
            throw decode(context + " is outside uint64", error);
        }
        throw decode(context + " must be a uint64");
    }

    public static int int32(Object value, String context) {
        BigInteger integer = integer(value, context);
        try {
            return integer.intValueExact();
        } catch (ArithmeticException error) {
            throw decode(context + " is outside int32", error);
        }
    }

    public static long int64(Object value, String context) {
        BigInteger integer = integer(value, context);
        try {
            return integer.longValueExact();
        } catch (ArithmeticException error) {
            throw decode(context + " is outside int64", error);
        }
    }

    public static long usize(Object value, String context) {
        BigInteger integer = integer(value, context);
        if (integer.signum() < 0 || integer.bitLength() > 63) {
            throw decode(context + " is outside Java's supported usize range");
        }
        return integer.longValue();
    }

    public static double float64(Object value, String context) {
        if (!(value instanceof Number number)) {
            throw decode(context + " must be a number");
        }
        double result = number.doubleValue();
        if (!Double.isFinite(result)) {
            throw decode(context + " must be finite");
        }
        return result;
    }

    public static Bytes bytes(Object value, String context) {
        try {
            return Bytes.fromBase64(string(value, context));
        } catch (IllegalArgumentException error) {
            throw decode(context + " must be valid base64", error);
        }
    }

    public static <T> List<T> array(
        Object value,
        String context,
        Function<Object, T> decoder
    ) {
        if (!(value instanceof List<?> raw)) {
            throw decode(context + " must be an array");
        }
        ArrayList<T> result = new ArrayList<>(raw.size());
        for (int index = 0; index < raw.size(); index++) {
            result.add(decoder.apply(raw.get(index)));
        }
        return List.copyOf(result);
    }

    public static <T> Map<String, T> map(
        Object value,
        String context,
        Function<Object, T> decoder
    ) {
        Map<String, Object> raw = object(value, context);
        LinkedHashMap<String, T> result = new LinkedHashMap<>();
        raw.forEach((key, item) -> result.put(key, decoder.apply(item)));
        return Collections.unmodifiableMap(result);
    }

    public static Object immutableJson(Object value) {
        if (value == null || value instanceof String || value instanceof Boolean
                || value instanceof BigInteger || value instanceof BigDecimal
                || value instanceof Byte || value instanceof Short || value instanceof Integer
                || value instanceof Long || value instanceof Double || value instanceof Float) {
            return value;
        }
        if (value instanceof UInt64 unsigned) {
            return unsigned;
        }
        if (value instanceof List<?> list) {
            return list.stream().map(Wire::immutableJson).toList();
        }
        if (value instanceof Map<?, ?> raw) {
            LinkedHashMap<String, Object> result = new LinkedHashMap<>();
            raw.forEach((key, item) -> {
                if (!(key instanceof String name)) {
                    throw decode("JSON object has a non-string key");
                }
                result.put(name, immutableJson(item));
            });
            return Collections.unmodifiableMap(result);
        }
        throw decode("unsupported JSON value " + value.getClass().getName());
    }

    public static Object encode(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof WireValue wireValue) {
            return encode(wireValue.toWire());
        }
        if (value instanceof WireEnum wireEnum) {
            return wireEnum.wireValue();
        }
        if (value instanceof Bytes bytes) {
            return bytes.toBase64();
        }
        if (value instanceof UInt64 unsigned) {
            return unsigned.toBigInteger();
        }
        if (value instanceof Field<?> field) {
            if (!field.isPresent()) {
                return Missing.VALUE;
            }
            return encode(field.value());
        }
        if (value instanceof List<?> list) {
            return list.stream().map(Wire::encode).toList();
        }
        if (value instanceof Map<?, ?> raw) {
            LinkedHashMap<String, Object> result = new LinkedHashMap<>();
            raw.forEach((key, item) -> {
                if (!(key instanceof String name)) {
                    throw new IllegalArgumentException("wire map keys must be strings");
                }
                Object encoded = encode(item);
                if (encoded != Missing.VALUE) {
                    result.put(name, encoded);
                }
            });
            return result;
        }
        if (value instanceof String || value instanceof Boolean || value instanceof Number) {
            return value;
        }
        throw new IllegalArgumentException("unsupported wire value " + value.getClass().getName());
    }

    public static void put(Map<String, Object> target, String name, Object value) {
        Object encoded = encode(value);
        if (encoded != Missing.VALUE) {
            target.put(name, encoded);
        }
    }

    public static <T> T nonNull(T value, String name) {
        return Objects.requireNonNull(value, name);
    }

    public static CmuxDecodeException decode(String message) {
        return new CmuxDecodeException(message, null);
    }

    public static CmuxDecodeException decode(String message, Throwable cause) {
        return new CmuxDecodeException(message, cause);
    }

    private static int boundedInt(Object value, long max, String context) {
        BigInteger integer = integer(value, context);
        if (integer.signum() < 0 || integer.compareTo(BigInteger.valueOf(max)) > 0) {
            throw decode(context + " is outside the expected unsigned range");
        }
        return integer.intValue();
    }

    private static BigInteger integer(Object value, String context) {
        if (value instanceof BigInteger integer) {
            return integer;
        }
        if (value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long) {
            return BigInteger.valueOf(((Number) value).longValue());
        }
        throw decode(context + " must be an integer");
    }

    private enum Missing {
        VALUE
    }
}

package com.cmux.raw;

import java.util.Arrays;
import java.util.Base64;

/** Immutable binary protocol value encoded as base64 on the wire. */
public final class Bytes {
    private static final Bytes EMPTY = new Bytes(new byte[0], false);
    private final byte[] value;

    private Bytes(byte[] value, boolean copy) {
        this.value = copy ? value.clone() : value;
    }

    public static Bytes of(byte[] value) {
        if (value.length == 0) {
            return EMPTY;
        }
        return new Bytes(value, true);
    }

    public static Bytes fromBase64(String value) {
        byte[] decoded = Base64.getDecoder().decode(value);
        return decoded.length == 0 ? EMPTY : new Bytes(decoded, false);
    }

    public byte[] toByteArray() {
        return value.clone();
    }

    public String toBase64() {
        return Base64.getEncoder().encodeToString(value);
    }

    public int size() {
        return value.length;
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Bytes that && Arrays.equals(value, that.value);
    }

    @Override
    public int hashCode() {
        return Arrays.hashCode(value);
    }

    @Override
    public String toString() {
        return "Bytes[" + value.length + "]";
    }
}

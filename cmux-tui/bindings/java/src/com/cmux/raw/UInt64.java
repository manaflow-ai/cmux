package com.cmux.raw;

import java.math.BigInteger;
import java.util.Objects;

/** Lossless immutable value for cmux protocol uint64 numbers. */
public final class UInt64 extends Number implements Comparable<UInt64> {
    private static final long serialVersionUID = 1L;
    public static final UInt64 ZERO = new UInt64(BigInteger.ZERO);
    public static final UInt64 MAX_VALUE = new UInt64(
        BigInteger.ONE.shiftLeft(64).subtract(BigInteger.ONE)
    );

    private final BigInteger value;

    private UInt64(BigInteger value) {
        this.value = value;
    }

    public static UInt64 of(long value) {
        if (value < 0) {
            throw new IllegalArgumentException("uint64 cannot be negative");
        }
        return value == 0 ? ZERO : new UInt64(BigInteger.valueOf(value));
    }

    /**
     * Interprets every bit in {@code bits} as unsigned, matching
     * {@link Long#toUnsignedString(long)}.
     */
    public static UInt64 fromUnsignedLong(long bits) {
        return parse(Long.toUnsignedString(bits));
    }

    public static UInt64 of(BigInteger value) {
        Objects.requireNonNull(value, "value");
        if (value.signum() < 0 || value.bitLength() > 64) {
            throw new IllegalArgumentException("uint64 is outside 0.." + MAX_VALUE);
        }
        return value.signum() == 0 ? ZERO : new UInt64(value);
    }

    public static UInt64 parse(String decimal) {
        Objects.requireNonNull(decimal, "decimal");
        if (decimal.isEmpty() || !decimal.chars().allMatch(c -> c >= '0' && c <= '9')) {
            throw new IllegalArgumentException("uint64 must be an unsigned decimal integer");
        }
        return of(new BigInteger(decimal));
    }

    public BigInteger toBigInteger() {
        return value;
    }

    public long toUnsignedLongBits() {
        return value.longValue();
    }

    public long longValueExact() {
        return value.longValueExact();
    }

    @Override
    public int intValue() {
        return value.intValue();
    }

    @Override
    public long longValue() {
        return value.longValue();
    }

    @Override
    public float floatValue() {
        return value.floatValue();
    }

    @Override
    public double doubleValue() {
        return value.doubleValue();
    }

    @Override
    public int compareTo(UInt64 other) {
        return value.compareTo(other.value);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof UInt64 that && value.equals(that.value);
    }

    @Override
    public int hashCode() {
        return value.hashCode();
    }

    @Override
    public String toString() {
        return value.toString();
    }
}

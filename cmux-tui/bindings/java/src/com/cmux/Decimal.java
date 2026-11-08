package com.cmux;

import java.math.BigInteger;
import java.util.Objects;

/** Canonical unsigned decimal string with the full uint64 range. */
public final class Decimal implements Comparable<Decimal> {
    public static final Decimal ZERO = new Decimal(BigInteger.ZERO);
    public static final Decimal MAX_VALUE =
        new Decimal(new BigInteger("18446744073709551615"));
    private final BigInteger value;

    private Decimal(BigInteger value) {
        this.value = value;
    }

    public static Decimal of(BigInteger value) {
        Objects.requireNonNull(value, "value");
        if (value.signum() < 0 || value.compareTo(MAX_VALUE.value) > 0) {
            throw new IllegalArgumentException("decimal is outside uint64");
        }
        return value.signum() == 0 ? ZERO : new Decimal(value);
    }

    public static Decimal parse(String value) {
        Objects.requireNonNull(value, "value");
        if (value.isEmpty() || value.length() > 20 || value.charAt(0) == '+' ||
                (value.length() > 1 && value.charAt(0) == '0')) {
            throw new IllegalArgumentException("invalid canonical unsigned decimal");
        }
        try {
            return of(new BigInteger(value));
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException("invalid canonical unsigned decimal", error);
        }
    }

    public BigInteger value() {
        return value;
    }

    public String toWire() {
        return value.toString();
    }

    @Override
    public int compareTo(Decimal other) {
        return value.compareTo(other.value);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Decimal decimal && value.equals(decimal.value);
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

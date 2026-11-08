package com.cmux;

import java.util.Objects;

/** Sensitive wire string whose normal formatting is always redacted. */
public final class Secret {
    private final String value;

    public Secret(String value) {
        this.value = Objects.requireNonNull(value, "value");
        if (value.isEmpty()) {
            throw new IllegalArgumentException("secret must not be empty");
        }
    }

    public String reveal() {
        return value;
    }

    @Override
    public String toString() {
        return "<redacted>";
    }
}

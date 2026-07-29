package com.cmux;

import java.nio.charset.StandardCharsets;
import java.util.Objects;

/** Sensitive provider-owned machine specifier with explicitly revealable wire bytes. */
public final class ExternalMachineSpecifier {
    private final String value;

    public ExternalMachineSpecifier(String value) {
        this.value = Objects.requireNonNull(value, "value");
        int bytes = value.getBytes(StandardCharsets.UTF_8).length;
        if (bytes == 0 || bytes > 512) {
            throw new IllegalArgumentException(
                "external machine specifier must contain 1 to 512 UTF-8 bytes"
            );
        }
        for (int index = 0; index < value.length();) {
            int codePoint = value.codePointAt(index);
            if (Character.isISOControl(codePoint)) {
                throw new IllegalArgumentException(
                    "external machine specifier must not contain control characters"
                );
            }
            index += Character.charCount(codePoint);
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

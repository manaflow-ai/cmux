package com.cmux;

import java.util.Objects;

public record MutationResult<T>(
    T value,
    String generation,
    Decimal revision,
    boolean replayed
) {
    public MutationResult {
        Objects.requireNonNull(generation, "generation");
        if (generation.isEmpty() || generation.length() > 128) {
            throw new IllegalArgumentException(
                "generation must contain 1 to 128 characters"
            );
        }
        Objects.requireNonNull(revision, "revision");
    }
}

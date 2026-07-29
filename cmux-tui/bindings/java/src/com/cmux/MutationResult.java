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
        if (generation.isEmpty()) {
            throw new IllegalArgumentException("generation must not be empty");
        }
        Objects.requireNonNull(revision, "revision");
    }
}

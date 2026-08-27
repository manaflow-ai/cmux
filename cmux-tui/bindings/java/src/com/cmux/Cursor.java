package com.cmux;

import java.util.Objects;

public record Cursor(String generation, Decimal revision) {
    public Cursor {
        Objects.requireNonNull(generation, "generation");
        Objects.requireNonNull(revision, "revision");
    }
}

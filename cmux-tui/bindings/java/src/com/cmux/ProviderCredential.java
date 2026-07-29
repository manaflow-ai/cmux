package com.cmux;

import java.util.Objects;

public record ProviderCredential(String name, Secret value) {
    public ProviderCredential {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(value, "value");
        if (name.isEmpty()) {
            throw new IllegalArgumentException("credential name must not be empty");
        }
    }

    @Override
    public String toString() {
        return "ProviderCredential[name=" + name + ", value=<redacted>]";
    }
}

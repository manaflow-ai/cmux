package com.cmux;

import java.util.Map;
import java.util.Objects;

public record EnsureTerminalEnvironment(String name, String value) {
    public EnsureTerminalEnvironment {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(value, "value");
    }

    Map<String, Object> toMap() {
        return Map.of("name", name, "value", value);
    }
}

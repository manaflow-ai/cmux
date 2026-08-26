package com.cmux;

import com.cmux.internal.Wire;
import java.util.Map;
import java.util.Objects;

/** Script evaluated by the target session's platform shell. */
public record ShellCommand(String script) implements Command {
    public ShellCommand {
        Objects.requireNonNull(script, "script");
        if (script.isEmpty()) {
            throw new IllegalArgumentException("script must not be empty");
        }
    }

    @Override
    public Map<String, Object> toWire() {
        return Wire.map(Wire.SHELL, script);
    }
}

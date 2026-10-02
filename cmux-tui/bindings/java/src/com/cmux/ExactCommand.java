package com.cmux;

import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Exact argv. No item is interpreted by a local or remote shell. */
public final class ExactCommand implements Command {
    private final List<String> argv;

    private ExactCommand(List<String> argv) {
        if (argv.isEmpty() || argv.get(0).isEmpty()) {
            throw new IllegalArgumentException("argv must contain a non-empty executable");
        }
        this.argv = List.copyOf(argv);
    }

    public static ExactCommand of(String... argv) {
        return new ExactCommand(Arrays.asList(argv.clone()));
    }

    public static Builder builder() {
        return new Builder();
    }

    public List<String> argv() {
        return argv;
    }

    @Override
    public Map<String, Object> toWire() {
        return Wire.map(Wire.ARGV, argv);
    }

    public static final class Builder {
        private final List<String> argv = new ArrayList<>();

        public Builder arg(String value) {
            argv.add(Objects.requireNonNull(value, "value"));
            return this;
        }

        public ExactCommand build() {
            return new ExactCommand(argv);
        }
    }
}

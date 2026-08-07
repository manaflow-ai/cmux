// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalExit implements WireValue {
    private final UInt64 exitedAtMs;
    private final TerminalExitOutcome outcome;

    private TerminalExit(Builder builder) {
        if (!builder.exitedAtMsSet) throw new IllegalArgumentException("exited_at_ms is required");
        this.exitedAtMs = Wire.nonNull(builder.exitedAtMs, "exited_at_ms");
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 exitedAtMs() { return exitedAtMs; }
    public TerminalExitOutcome outcome() { return outcome; }

    public static TerminalExit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalExit");
        Builder builder = builder();
        Object rawExitedAtMs = Wire.required(object, "exited_at_ms");
        builder.exitedAtMs(Wire.uint64(rawExitedAtMs, "TerminalExit.exited_at_ms"));
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(TerminalExitOutcome.fromWire(rawOutcome));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "exited_at_ms", exitedAtMs);
        Wire.put(object, "outcome", outcome);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalExit that)) return false;
        return Objects.equals(exitedAtMs, that.exitedAtMs) && Objects.equals(outcome, that.outcome);
    }

    @Override
    public int hashCode() { return Objects.hash(exitedAtMs, outcome); }

    @Override
    public String toString() { return "TerminalExit" + toWire(); }

    public static final class Builder {
        private UInt64 exitedAtMs;
        private boolean exitedAtMsSet;
        private TerminalExitOutcome outcome;
        private boolean outcomeSet;

        public Builder exitedAtMs(UInt64 value) {
            this.exitedAtMs = value;
            this.exitedAtMsSet = true;
            return this;
        }
        public Builder outcome(TerminalExitOutcome value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public TerminalExit build() { return new TerminalExit(this); }
    }
}

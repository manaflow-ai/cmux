// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalExitOutcomeSignal implements WireValue, TerminalExitOutcome {
    private final boolean coreDumped;
    private final int signal;

    private TerminalExitOutcomeSignal(Builder builder) {
        if (!builder.coreDumpedSet) throw new IllegalArgumentException("core_dumped is required");
        this.coreDumped = builder.coreDumped;
        if (!builder.signalSet) throw new IllegalArgumentException("signal is required");
        this.signal = builder.signal;
    }

    public static Builder builder() { return new Builder(); }

    public boolean coreDumped() { return coreDumped; }
    public String kind() { return "signal"; }
    public int signal() { return signal; }

    public static TerminalExitOutcomeSignal fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalExitOutcomeSignal");
        Builder builder = builder();
        Object rawCoreDumped = Wire.required(object, "core_dumped");
        builder.coreDumped(Wire.bool(rawCoreDumped, "TerminalExitOutcomeSignal.core_dumped"));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "signal", "TerminalExitOutcomeSignal.kind");
        Object rawSignal = Wire.required(object, "signal");
        builder.signal(Wire.int32(rawSignal, "TerminalExitOutcomeSignal.signal"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "core_dumped", coreDumped);
        Wire.put(object, "kind", "signal");
        Wire.put(object, "signal", signal);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalExitOutcomeSignal that)) return false;
        return Objects.equals(coreDumped, that.coreDumped) && Objects.equals(signal, that.signal);
    }

    @Override
    public int hashCode() { return Objects.hash(coreDumped, signal); }

    @Override
    public String toString() { return "TerminalExitOutcomeSignal" + toWire(); }

    public static final class Builder {
        private Boolean coreDumped;
        private boolean coreDumpedSet;
        private Integer signal;
        private boolean signalSet;

        public Builder coreDumped(boolean value) {
            this.coreDumped = value;
            this.coreDumpedSet = true;
            return this;
        }
        public Builder signal(int value) {
            this.signal = value;
            this.signalSet = true;
            return this;
        }
        public TerminalExitOutcomeSignal build() { return new TerminalExitOutcomeSignal(this); }
    }
}

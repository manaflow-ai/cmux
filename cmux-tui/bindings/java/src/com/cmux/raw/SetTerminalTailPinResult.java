// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetTerminalTailPinResult implements WireValue {
    private final boolean pinned;
    private final String terminal;

    private SetTerminalTailPinResult(Builder builder) {
        if (!builder.pinnedSet) throw new IllegalArgumentException("pinned is required");
        this.pinned = builder.pinned;
        if (!builder.terminalSet) throw new IllegalArgumentException("terminal is required");
        this.terminal = Wire.nonNull(builder.terminal, "terminal");
    }

    public static Builder builder() { return new Builder(); }

    public boolean pinned() { return pinned; }
    public String terminal() { return terminal; }

    public static SetTerminalTailPinResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalTailPinResult");
        Builder builder = builder();
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "SetTerminalTailPinResult.pinned"));
        Object rawTerminal = Wire.required(object, "terminal");
        builder.terminal(Wire.string(rawTerminal, "SetTerminalTailPinResult.terminal"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "terminal", terminal);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalTailPinResult that)) return false;
        return Objects.equals(pinned, that.pinned) && Objects.equals(terminal, that.terminal);
    }

    @Override
    public int hashCode() { return Objects.hash(pinned, terminal); }

    @Override
    public String toString() { return "SetTerminalTailPinResult" + toWire(); }

    public static final class Builder {
        private Boolean pinned;
        private boolean pinnedSet;
        private String terminal;
        private boolean terminalSet;

        public Builder pinned(boolean value) {
            this.pinned = value;
            this.pinnedSet = true;
            return this;
        }
        public Builder terminal(String value) {
            this.terminal = value;
            this.terminalSet = true;
            return this;
        }
        public SetTerminalTailPinResult build() { return new SetTerminalTailPinResult(this); }
    }
}

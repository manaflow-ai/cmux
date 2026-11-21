// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-terminal-tail-pin request. Protocol v12; authority: control. */
public final class SetTerminalTailPinRequest implements WireValue {
    private final boolean pinned;
    private final Field<UInt64> surface;
    private final Field<String> terminal;

    private SetTerminalTailPinRequest(Builder builder) {
        if (!builder.pinnedSet) throw new IllegalArgumentException("pinned is required");
        this.pinned = builder.pinned;
        this.surface = builder.surface;
        this.terminal = builder.terminal;
    }

    public static Builder builder() { return new Builder(); }

    public boolean pinned() { return pinned; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminal() { return terminal; }

    public static SetTerminalTailPinRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalTailPinRequest");
        Builder builder = builder();
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "SetTerminalTailPinRequest.pinned"));
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SetTerminalTailPinRequest.surface"));
        }
        Object rawTerminal = Wire.optional(object, "terminal");
        if (!Wire.isMissing(rawTerminal)) {
            builder.terminal(rawTerminal == null ? null : Wire.string(rawTerminal, "SetTerminalTailPinRequest.terminal"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal", terminal);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalTailPinRequest that)) return false;
        return Objects.equals(pinned, that.pinned) && Objects.equals(surface, that.surface) && Objects.equals(terminal, that.terminal);
    }

    @Override
    public int hashCode() { return Objects.hash(pinned, surface, terminal); }

    @Override
    public String toString() { return "SetTerminalTailPinRequest" + toWire(); }

    public static final class Builder {
        private Boolean pinned;
        private boolean pinnedSet;
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminal = Field.omitted();

        public Builder pinned(boolean value) {
            this.pinned = value;
            this.pinnedSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder terminal(String value) {
            this.terminal = Field.ofNullable(value);
            return this;
        }
        public SetTerminalTailPinRequest build() { return new SetTerminalTailPinRequest(this); }
    }
}

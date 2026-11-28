// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-terminal-notify-when-done request. Protocol v12; authority: control. */
public final class SetTerminalNotifyWhenDoneRequest implements WireValue {
    private final boolean on;
    private final Field<UInt64> surface;
    private final Field<String> terminal;

    private SetTerminalNotifyWhenDoneRequest(Builder builder) {
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
        this.surface = builder.surface;
        this.terminal = builder.terminal;
    }

    public static Builder builder() { return new Builder(); }

    public boolean on() { return on; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminal() { return terminal; }

    public static SetTerminalNotifyWhenDoneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalNotifyWhenDoneRequest");
        Builder builder = builder();
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "SetTerminalNotifyWhenDoneRequest.on"));
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SetTerminalNotifyWhenDoneRequest.surface"));
        }
        Object rawTerminal = Wire.optional(object, "terminal");
        if (!Wire.isMissing(rawTerminal)) {
            builder.terminal(rawTerminal == null ? null : Wire.string(rawTerminal, "SetTerminalNotifyWhenDoneRequest.terminal"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "on", on);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal", terminal);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalNotifyWhenDoneRequest that)) return false;
        return Objects.equals(on, that.on) && Objects.equals(surface, that.surface) && Objects.equals(terminal, that.terminal);
    }

    @Override
    public int hashCode() { return Objects.hash(on, surface, terminal); }

    @Override
    public String toString() { return "SetTerminalNotifyWhenDoneRequest" + toWire(); }

    public static final class Builder {
        private Boolean on;
        private boolean onSet;
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminal = Field.omitted();

        public Builder on(boolean value) {
            this.on = value;
            this.onSet = true;
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
        public SetTerminalNotifyWhenDoneRequest build() { return new SetTerminalNotifyWhenDoneRequest(this); }
    }
}

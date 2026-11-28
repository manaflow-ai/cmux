// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetTerminalNotifyWhenDoneResult implements WireValue {
    private final boolean on;
    private final String terminal;

    private SetTerminalNotifyWhenDoneResult(Builder builder) {
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
        if (!builder.terminalSet) throw new IllegalArgumentException("terminal is required");
        this.terminal = Wire.nonNull(builder.terminal, "terminal");
    }

    public static Builder builder() { return new Builder(); }

    public boolean on() { return on; }
    public String terminal() { return terminal; }

    public static SetTerminalNotifyWhenDoneResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalNotifyWhenDoneResult");
        Builder builder = builder();
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "SetTerminalNotifyWhenDoneResult.on"));
        Object rawTerminal = Wire.required(object, "terminal");
        builder.terminal(Wire.string(rawTerminal, "SetTerminalNotifyWhenDoneResult.terminal"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "on", on);
        Wire.put(object, "terminal", terminal);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalNotifyWhenDoneResult that)) return false;
        return Objects.equals(on, that.on) && Objects.equals(terminal, that.terminal);
    }

    @Override
    public int hashCode() { return Objects.hash(on, terminal); }

    @Override
    public String toString() { return "SetTerminalNotifyWhenDoneResult" + toWire(); }

    public static final class Builder {
        private Boolean on;
        private boolean onSet;
        private String terminal;
        private boolean terminalSet;

        public Builder on(boolean value) {
            this.on = value;
            this.onSet = true;
            return this;
        }
        public Builder terminal(String value) {
            this.terminal = value;
            this.terminalSet = true;
            return this;
        }
        public SetTerminalNotifyWhenDoneResult build() { return new SetTerminalNotifyWhenDoneResult(this); }
    }
}

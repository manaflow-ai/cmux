// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetTerminalIdlePolicyResult implements WireValue {
    private final UInt64 idleCloseSeconds;
    private final String terminalId;

    private SetTerminalIdlePolicyResult(Builder builder) {
        if (!builder.idleCloseSecondsSet) throw new IllegalArgumentException("idle_close_seconds is required");
        this.idleCloseSeconds = builder.idleCloseSeconds;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 idleCloseSeconds() { return idleCloseSeconds; }
    public String terminalId() { return terminalId; }

    public static SetTerminalIdlePolicyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalIdlePolicyResult");
        Builder builder = builder();
        Object rawIdleCloseSeconds = Wire.required(object, "idle_close_seconds");
        builder.idleCloseSeconds(rawIdleCloseSeconds == null ? null : Wire.uint64(rawIdleCloseSeconds, "SetTerminalIdlePolicyResult.idle_close_seconds"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "SetTerminalIdlePolicyResult.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "idle_close_seconds", idleCloseSeconds);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalIdlePolicyResult that)) return false;
        return Objects.equals(idleCloseSeconds, that.idleCloseSeconds) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(idleCloseSeconds, terminalId); }

    @Override
    public String toString() { return "SetTerminalIdlePolicyResult" + toWire(); }

    public static final class Builder {
        private UInt64 idleCloseSeconds;
        private boolean idleCloseSecondsSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder idleCloseSeconds(UInt64 value) {
            this.idleCloseSeconds = value;
            this.idleCloseSecondsSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public SetTerminalIdlePolicyResult build() { return new SetTerminalIdlePolicyResult(this); }
    }
}

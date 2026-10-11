// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-terminal-idle-policy request. Protocol v12; authority: control. */
public final class SetTerminalIdlePolicyRequest implements WireValue {
    private final Field<UInt64> idleCloseSeconds;
    private final Field<UInt64> surface;
    private final Field<String> terminalId;

    private SetTerminalIdlePolicyRequest(Builder builder) {
        this.idleCloseSeconds = builder.idleCloseSeconds;
        this.surface = builder.surface;
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> idleCloseSeconds() { return idleCloseSeconds; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }

    public static SetTerminalIdlePolicyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalIdlePolicyRequest");
        Builder builder = builder();
        Object rawIdleCloseSeconds = Wire.optional(object, "idle_close_seconds");
        if (!Wire.isMissing(rawIdleCloseSeconds)) {
            builder.idleCloseSeconds(rawIdleCloseSeconds == null ? null : Wire.uint64(rawIdleCloseSeconds, "SetTerminalIdlePolicyRequest.idle_close_seconds"));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SetTerminalIdlePolicyRequest.surface"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SetTerminalIdlePolicyRequest.terminal_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "idle_close_seconds", idleCloseSeconds);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalIdlePolicyRequest that)) return false;
        return Objects.equals(idleCloseSeconds, that.idleCloseSeconds) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(idleCloseSeconds, surface, terminalId); }

    @Override
    public String toString() { return "SetTerminalIdlePolicyRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> idleCloseSeconds = Field.omitted();
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminalId = Field.omitted();

        public Builder idleCloseSeconds(UInt64 value) {
            this.idleCloseSeconds = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public SetTerminalIdlePolicyRequest build() { return new SetTerminalIdlePolicyRequest(this); }
    }
}

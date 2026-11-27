// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-last-command request. Protocol v12; authority: control. */
public final class TerminalLastCommandRequest implements WireValue {
    private final Field<UInt64> surface;
    private final Field<String> terminalId;

    private TerminalLastCommandRequest(Builder builder) {
        this.surface = builder.surface;
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }

    public static TerminalLastCommandRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalLastCommandRequest");
        Builder builder = builder();
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "TerminalLastCommandRequest.surface"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "TerminalLastCommandRequest.terminal_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalLastCommandRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, terminalId); }

    @Override
    public String toString() { return "TerminalLastCommandRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminalId = Field.omitted();

        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public TerminalLastCommandRequest build() { return new TerminalLastCommandRequest(this); }
    }
}

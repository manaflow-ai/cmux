// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-resume-command request. Protocol v12; authority: control. */
public final class TerminalResumeCommandRequest implements WireValue {
    private final Field<String> command;
    private final Field<UInt64> surface;
    private final Field<String> terminalId;

    private TerminalResumeCommandRequest(Builder builder) {
        this.command = builder.command;
        this.surface = builder.surface;
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> command() { return command; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }

    public static TerminalResumeCommandRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResumeCommandRequest");
        Builder builder = builder();
        Object rawCommand = Wire.optional(object, "command");
        if (!Wire.isMissing(rawCommand)) {
            builder.command(rawCommand == null ? null : Wire.string(rawCommand, "TerminalResumeCommandRequest.command"));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "TerminalResumeCommandRequest.surface"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "TerminalResumeCommandRequest.terminal_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalResumeCommandRequest that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(command, surface, terminalId); }

    @Override
    public String toString() { return "TerminalResumeCommandRequest" + toWire(); }

    public static final class Builder {
        private Field<String> command = Field.omitted();
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminalId = Field.omitted();

        public Builder command(String value) {
            this.command = Field.ofNullable(value);
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
        public TerminalResumeCommandRequest build() { return new TerminalResumeCommandRequest(this); }
    }
}

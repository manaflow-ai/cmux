// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-terminal-resume-command request. Protocol v12; authority: control. */
public final class SetTerminalResumeCommandRequest implements WireValue {
    private final String command;
    private final Field<UInt64> surface;
    private final Field<String> terminalId;

    private SetTerminalResumeCommandRequest(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = builder.command;
        this.surface = builder.surface;
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }

    public static SetTerminalResumeCommandRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalResumeCommandRequest");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(rawCommand == null ? null : Wire.string(rawCommand, "SetTerminalResumeCommandRequest.command"));
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SetTerminalResumeCommandRequest.surface"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SetTerminalResumeCommandRequest.terminal_id"));
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
        if (!(other instanceof SetTerminalResumeCommandRequest that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(command, surface, terminalId); }

    @Override
    public String toString() { return "SetTerminalResumeCommandRequest" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminalId = Field.omitted();

        public Builder command(String value) {
            this.command = value;
            this.commandSet = true;
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
        public SetTerminalResumeCommandRequest build() { return new SetTerminalResumeCommandRequest(this); }
    }
}

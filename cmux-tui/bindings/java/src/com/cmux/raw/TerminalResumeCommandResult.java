// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalResumeCommandResult implements WireValue {
    private final String command;
    private final String terminalId;

    private TerminalResumeCommandResult(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = builder.command;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public String terminalId() { return terminalId; }

    public static TerminalResumeCommandResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResumeCommandResult");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(rawCommand == null ? null : Wire.string(rawCommand, "TerminalResumeCommandResult.command"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalResumeCommandResult.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalResumeCommandResult that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(command, terminalId); }

    @Override
    public String toString() { return "TerminalResumeCommandResult" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder command(String value) {
            this.command = value;
            this.commandSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalResumeCommandResult build() { return new TerminalResumeCommandResult(this); }
    }
}

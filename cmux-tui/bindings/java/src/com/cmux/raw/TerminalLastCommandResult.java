// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalLastCommandResult implements WireValue {
    private final TerminalLastCommand lastCommand;
    private final String terminalId;

    private TerminalLastCommandResult(Builder builder) {
        if (!builder.lastCommandSet) throw new IllegalArgumentException("last_command is required");
        this.lastCommand = builder.lastCommand;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public TerminalLastCommand lastCommand() { return lastCommand; }
    public String terminalId() { return terminalId; }

    public static TerminalLastCommandResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalLastCommandResult");
        Builder builder = builder();
        Object rawLastCommand = Wire.required(object, "last_command");
        builder.lastCommand(rawLastCommand == null ? null : TerminalLastCommand.fromWire(rawLastCommand));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalLastCommandResult.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "last_command", lastCommand);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalLastCommandResult that)) return false;
        return Objects.equals(lastCommand, that.lastCommand) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(lastCommand, terminalId); }

    @Override
    public String toString() { return "TerminalLastCommandResult" + toWire(); }

    public static final class Builder {
        private TerminalLastCommand lastCommand;
        private boolean lastCommandSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder lastCommand(TerminalLastCommand value) {
            this.lastCommand = value;
            this.lastCommandSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalLastCommandResult build() { return new TerminalLastCommandResult(this); }
    }
}

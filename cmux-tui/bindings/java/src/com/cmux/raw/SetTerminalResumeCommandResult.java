// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetTerminalResumeCommandResult implements WireValue {
    private final String resumeCommand;
    private final String terminalId;
    private final Field<String> terminalResourceId;

    private SetTerminalResumeCommandResult(Builder builder) {
        if (!builder.resumeCommandSet) throw new IllegalArgumentException("resume_command is required");
        this.resumeCommand = builder.resumeCommand;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        this.terminalResourceId = builder.terminalResourceId;
    }

    public static Builder builder() { return new Builder(); }

    public String resumeCommand() { return resumeCommand; }
    public String terminalId() { return terminalId; }
    public Field<String> terminalResourceId() { return terminalResourceId; }

    public static SetTerminalResumeCommandResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalResumeCommandResult");
        Builder builder = builder();
        Object rawResumeCommand = Wire.required(object, "resume_command");
        builder.resumeCommand(rawResumeCommand == null ? null : Wire.string(rawResumeCommand, "SetTerminalResumeCommandResult.resume_command"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "SetTerminalResumeCommandResult.terminal_id"));
        Object rawTerminalResourceId = Wire.optional(object, "terminal_resource_id");
        if (!Wire.isMissing(rawTerminalResourceId)) {
            builder.terminalResourceId(rawTerminalResourceId == null ? null : Wire.string(rawTerminalResourceId, "SetTerminalResumeCommandResult.terminal_resource_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "resume_command", resumeCommand);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_resource_id", terminalResourceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalResumeCommandResult that)) return false;
        return Objects.equals(resumeCommand, that.resumeCommand) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalResourceId, that.terminalResourceId);
    }

    @Override
    public int hashCode() { return Objects.hash(resumeCommand, terminalId, terminalResourceId); }

    @Override
    public String toString() { return "SetTerminalResumeCommandResult" + toWire(); }

    public static final class Builder {
        private String resumeCommand;
        private boolean resumeCommandSet;
        private String terminalId;
        private boolean terminalIdSet;
        private Field<String> terminalResourceId = Field.omitted();

        public Builder resumeCommand(String value) {
            this.resumeCommand = value;
            this.resumeCommandSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder terminalResourceId(String value) {
            this.terminalResourceId = Field.ofNullable(value);
            return this;
        }
        public SetTerminalResumeCommandResult build() { return new SetTerminalResumeCommandResult(this); }
    }
}

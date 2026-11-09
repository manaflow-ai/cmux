// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalLastCommand implements WireValue {
    private final String command;
    private final String endedAtMs;
    private final Integer exitCode;
    private final String startedAtMs;

    private TerminalLastCommand(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = Wire.nonNull(builder.command, "command");
        if (!builder.endedAtMsSet) throw new IllegalArgumentException("ended_at_ms is required");
        this.endedAtMs = Wire.nonNull(builder.endedAtMs, "ended_at_ms");
        if (!builder.exitCodeSet) throw new IllegalArgumentException("exit_code is required");
        this.exitCode = builder.exitCode;
        if (!builder.startedAtMsSet) throw new IllegalArgumentException("started_at_ms is required");
        this.startedAtMs = Wire.nonNull(builder.startedAtMs, "started_at_ms");
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public String endedAtMs() { return endedAtMs; }
    public Integer exitCode() { return exitCode; }
    public String startedAtMs() { return startedAtMs; }

    public static TerminalLastCommand fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalLastCommand");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(Wire.string(rawCommand, "TerminalLastCommand.command"));
        Object rawEndedAtMs = Wire.required(object, "ended_at_ms");
        builder.endedAtMs(Wire.string(rawEndedAtMs, "TerminalLastCommand.ended_at_ms"));
        Object rawExitCode = Wire.required(object, "exit_code");
        builder.exitCode(rawExitCode == null ? null : Wire.int32(rawExitCode, "TerminalLastCommand.exit_code"));
        Object rawStartedAtMs = Wire.required(object, "started_at_ms");
        builder.startedAtMs(Wire.string(rawStartedAtMs, "TerminalLastCommand.started_at_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "ended_at_ms", endedAtMs);
        Wire.put(object, "exit_code", exitCode);
        Wire.put(object, "started_at_ms", startedAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalLastCommand that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(endedAtMs, that.endedAtMs) && Objects.equals(exitCode, that.exitCode) && Objects.equals(startedAtMs, that.startedAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(command, endedAtMs, exitCode, startedAtMs); }

    @Override
    public String toString() { return "TerminalLastCommand" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private String endedAtMs;
        private boolean endedAtMsSet;
        private Integer exitCode;
        private boolean exitCodeSet;
        private String startedAtMs;
        private boolean startedAtMsSet;

        public Builder command(String value) {
            this.command = value;
            this.commandSet = true;
            return this;
        }
        public Builder endedAtMs(String value) {
            this.endedAtMs = value;
            this.endedAtMsSet = true;
            return this;
        }
        public Builder exitCode(Integer value) {
            this.exitCode = value;
            this.exitCodeSet = true;
            return this;
        }
        public Builder startedAtMs(String value) {
            this.startedAtMs = value;
            this.startedAtMsSet = true;
            return this;
        }
        public TerminalLastCommand build() { return new TerminalLastCommand(this); }
    }
}

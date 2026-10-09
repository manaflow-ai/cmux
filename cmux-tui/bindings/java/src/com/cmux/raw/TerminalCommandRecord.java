// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalCommandRecord implements WireValue {
    private final String command;
    private final String cwd;
    private final String durationMs;
    private final Integer exitCode;
    private final String id;
    private final String startedAtMs;
    private final String terminalId;

    private TerminalCommandRecord(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = builder.command;
        if (!builder.cwdSet) throw new IllegalArgumentException("cwd is required");
        this.cwd = builder.cwd;
        if (!builder.durationMsSet) throw new IllegalArgumentException("duration_ms is required");
        this.durationMs = Wire.nonNull(builder.durationMs, "duration_ms");
        if (!builder.exitCodeSet) throw new IllegalArgumentException("exit_code is required");
        this.exitCode = builder.exitCode;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.startedAtMsSet) throw new IllegalArgumentException("started_at_ms is required");
        this.startedAtMs = Wire.nonNull(builder.startedAtMs, "started_at_ms");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public String cwd() { return cwd; }
    public String durationMs() { return durationMs; }
    public Integer exitCode() { return exitCode; }
    public String id() { return id; }
    public String startedAtMs() { return startedAtMs; }
    public String terminalId() { return terminalId; }

    public static TerminalCommandRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalCommandRecord");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(rawCommand == null ? null : Wire.string(rawCommand, "TerminalCommandRecord.command"));
        Object rawCwd = Wire.required(object, "cwd");
        builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "TerminalCommandRecord.cwd"));
        Object rawDurationMs = Wire.required(object, "duration_ms");
        builder.durationMs(Wire.string(rawDurationMs, "TerminalCommandRecord.duration_ms"));
        Object rawExitCode = Wire.required(object, "exit_code");
        builder.exitCode(rawExitCode == null ? null : Wire.int32(rawExitCode, "TerminalCommandRecord.exit_code"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "TerminalCommandRecord.id"));
        Object rawStartedAtMs = Wire.required(object, "started_at_ms");
        builder.startedAtMs(Wire.string(rawStartedAtMs, "TerminalCommandRecord.started_at_ms"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalCommandRecord.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "duration_ms", durationMs);
        Wire.put(object, "exit_code", exitCode);
        Wire.put(object, "id", id);
        Wire.put(object, "started_at_ms", startedAtMs);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalCommandRecord that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd) && Objects.equals(durationMs, that.durationMs) && Objects.equals(exitCode, that.exitCode) && Objects.equals(id, that.id) && Objects.equals(startedAtMs, that.startedAtMs) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(command, cwd, durationMs, exitCode, id, startedAtMs, terminalId); }

    @Override
    public String toString() { return "TerminalCommandRecord" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private String cwd;
        private boolean cwdSet;
        private String durationMs;
        private boolean durationMsSet;
        private Integer exitCode;
        private boolean exitCodeSet;
        private String id;
        private boolean idSet;
        private String startedAtMs;
        private boolean startedAtMsSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder command(String value) {
            this.command = value;
            this.commandSet = true;
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = value;
            this.cwdSet = true;
            return this;
        }
        public Builder durationMs(String value) {
            this.durationMs = value;
            this.durationMsSet = true;
            return this;
        }
        public Builder exitCode(Integer value) {
            this.exitCode = value;
            this.exitCodeSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder startedAtMs(String value) {
            this.startedAtMs = value;
            this.startedAtMsSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalCommandRecord build() { return new TerminalCommandRecord(this); }
    }
}

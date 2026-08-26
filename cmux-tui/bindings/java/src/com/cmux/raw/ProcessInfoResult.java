// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ProcessInfoResult implements WireValue {
    private final String command;
    private final String cwd;
    /** Working directory of the process group that owns the PTY, read at request time. Null when the lookup fails; absent from daemons that predate the field. Clients treat absence as null. */
    private final Field<String> foregroundCwd;
    private final Long pid;

    private ProcessInfoResult(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = builder.command;
        if (!builder.cwdSet) throw new IllegalArgumentException("cwd is required");
        this.cwd = builder.cwd;
        this.foregroundCwd = builder.foregroundCwd;
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public String cwd() { return cwd; }
    public Field<String> foregroundCwd() { return foregroundCwd; }
    public Long pid() { return pid; }

    public static ProcessInfoResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ProcessInfoResult");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(rawCommand == null ? null : Wire.string(rawCommand, "ProcessInfoResult.command"));
        Object rawCwd = Wire.required(object, "cwd");
        builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "ProcessInfoResult.cwd"));
        Object rawForegroundCwd = Wire.optional(object, "foreground_cwd");
        if (!Wire.isMissing(rawForegroundCwd)) {
            builder.foregroundCwd(rawForegroundCwd == null ? null : Wire.string(rawForegroundCwd, "ProcessInfoResult.foreground_cwd"));
        }
        Object rawPid = Wire.required(object, "pid");
        builder.pid(rawPid == null ? null : Wire.uint32(rawPid, "ProcessInfoResult.pid"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "foreground_cwd", foregroundCwd);
        Wire.put(object, "pid", pid);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ProcessInfoResult that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd) && Objects.equals(foregroundCwd, that.foregroundCwd) && Objects.equals(pid, that.pid);
    }

    @Override
    public int hashCode() { return Objects.hash(command, cwd, foregroundCwd, pid); }

    @Override
    public String toString() { return "ProcessInfoResult" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private String cwd;
        private boolean cwdSet;
        private Field<String> foregroundCwd = Field.omitted();
        private Long pid;
        private boolean pidSet;

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
        public Builder foregroundCwd(String value) {
            this.foregroundCwd = Field.ofNullable(value);
            return this;
        }
        public Builder pid(Long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public ProcessInfoResult build() { return new ProcessInfoResult(this); }
    }
}

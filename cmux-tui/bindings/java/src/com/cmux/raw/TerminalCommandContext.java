// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalCommandContext implements WireValue {
    private final String command;
    private final String cwd;
    private final Integer exitCode;
    private final String output;
    private final String text;
    private final boolean truncated;

    private TerminalCommandContext(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = builder.command;
        if (!builder.cwdSet) throw new IllegalArgumentException("cwd is required");
        this.cwd = builder.cwd;
        if (!builder.exitCodeSet) throw new IllegalArgumentException("exit_code is required");
        this.exitCode = builder.exitCode;
        if (!builder.outputSet) throw new IllegalArgumentException("output is required");
        this.output = Wire.nonNull(builder.output, "output");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
        if (!builder.truncatedSet) throw new IllegalArgumentException("truncated is required");
        this.truncated = builder.truncated;
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public String cwd() { return cwd; }
    public Integer exitCode() { return exitCode; }
    public String output() { return output; }
    public String text() { return text; }
    public boolean truncated() { return truncated; }

    public static TerminalCommandContext fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalCommandContext");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(rawCommand == null ? null : Wire.string(rawCommand, "TerminalCommandContext.command"));
        Object rawCwd = Wire.required(object, "cwd");
        builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "TerminalCommandContext.cwd"));
        Object rawExitCode = Wire.required(object, "exit_code");
        builder.exitCode(rawExitCode == null ? null : Wire.int32(rawExitCode, "TerminalCommandContext.exit_code"));
        Object rawOutput = Wire.required(object, "output");
        builder.output(Wire.string(rawOutput, "TerminalCommandContext.output"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "TerminalCommandContext.text"));
        Object rawTruncated = Wire.required(object, "truncated");
        builder.truncated(Wire.bool(rawTruncated, "TerminalCommandContext.truncated"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "exit_code", exitCode);
        Wire.put(object, "output", output);
        Wire.put(object, "text", text);
        Wire.put(object, "truncated", truncated);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalCommandContext that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd) && Objects.equals(exitCode, that.exitCode) && Objects.equals(output, that.output) && Objects.equals(text, that.text) && Objects.equals(truncated, that.truncated);
    }

    @Override
    public int hashCode() { return Objects.hash(command, cwd, exitCode, output, text, truncated); }

    @Override
    public String toString() { return "TerminalCommandContext" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private String cwd;
        private boolean cwdSet;
        private Integer exitCode;
        private boolean exitCodeSet;
        private String output;
        private boolean outputSet;
        private String text;
        private boolean textSet;
        private Boolean truncated;
        private boolean truncatedSet;

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
        public Builder exitCode(Integer value) {
            this.exitCode = value;
            this.exitCodeSet = true;
            return this;
        }
        public Builder output(String value) {
            this.output = value;
            this.outputSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public Builder truncated(boolean value) {
            this.truncated = value;
            this.truncatedSet = true;
            return this;
        }
        public TerminalCommandContext build() { return new TerminalCommandContext(this); }
    }
}

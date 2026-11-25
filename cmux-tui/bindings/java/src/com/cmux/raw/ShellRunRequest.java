// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable shell-run request. Protocol v12; authority: control. */
public final class ShellRunRequest implements WireValue {
    private final String command;
    private final Field<String> cwd;
    private final Field<String> run;
    private final Field<String> scope;

    private ShellRunRequest(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = Wire.nonNull(builder.command, "command");
        this.cwd = builder.cwd;
        this.run = builder.run;
        this.scope = builder.scope;
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public Field<String> cwd() { return cwd; }
    public Field<String> run() { return run; }
    public Field<String> scope() { return scope; }

    public static ShellRunRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ShellRunRequest");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(Wire.string(rawCommand, "ShellRunRequest.command"));
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "ShellRunRequest.cwd"));
        }
        Object rawRun = Wire.optional(object, "run");
        if (!Wire.isMissing(rawRun)) {
            builder.run(rawRun == null ? null : Wire.string(rawRun, "ShellRunRequest.run"));
        }
        Object rawScope = Wire.optional(object, "scope");
        if (!Wire.isMissing(rawScope)) {
            builder.scope(rawScope == null ? null : Wire.string(rawScope, "ShellRunRequest.scope"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "run", run);
        Wire.put(object, "scope", scope);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ShellRunRequest that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd) && Objects.equals(run, that.run) && Objects.equals(scope, that.scope);
    }

    @Override
    public int hashCode() { return Objects.hash(command, cwd, run, scope); }

    @Override
    public String toString() { return "ShellRunRequest" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private Field<String> cwd = Field.omitted();
        private Field<String> run = Field.omitted();
        private Field<String> scope = Field.omitted();

        public Builder command(String value) {
            this.command = value;
            this.commandSet = true;
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder run(String value) {
            this.run = Field.ofNullable(value);
            return this;
        }
        public Builder scope(String value) {
            this.scope = Field.ofNullable(value);
            return this;
        }
        public ShellRunRequest build() { return new ShellRunRequest(this); }
    }
}

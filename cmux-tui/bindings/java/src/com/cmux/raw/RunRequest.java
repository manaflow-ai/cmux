// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable run request. Protocol v6; authority: control. */
public final class RunRequest implements WireValue {
    private final Field<List<String>> argv;
    private final Field<Integer> cols;
    private final Field<String> command;
    private final Field<String> cwd;
    private final Field<String> key;
    private final Field<String> name;
    private final Field<Boolean> newWorkspace;
    private final Field<UInt64> pane;
    private final Field<Integer> rows;

    private RunRequest(Builder builder) {
        this.argv = builder.argv.map(value -> List.copyOf(value));
        this.cols = builder.cols;
        this.command = builder.command;
        this.cwd = builder.cwd;
        this.key = builder.key;
        this.name = builder.name;
        this.newWorkspace = builder.newWorkspace;
        this.pane = builder.pane;
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> argv() { return argv; }
    public Field<Integer> cols() { return cols; }
    public Field<String> command() { return command; }
    public Field<String> cwd() { return cwd; }
    public Field<String> key() { return key; }
    public Field<String> name() { return name; }
    public Field<Boolean> newWorkspace() { return newWorkspace; }
    public Field<UInt64> pane() { return pane; }
    public Field<Integer> rows() { return rows; }

    public static RunRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RunRequest");
        Builder builder = builder();
        Object rawArgv = Wire.optional(object, "argv");
        if (!Wire.isMissing(rawArgv)) {
            builder.argv(rawArgv == null ? null : Wire.array(rawArgv, "RunRequest.argv", item -> Wire.string(item, "RunRequest.argv item")));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "RunRequest.cols"));
        }
        Object rawCommand = Wire.optional(object, "command");
        if (!Wire.isMissing(rawCommand)) {
            builder.command(rawCommand == null ? null : Wire.string(rawCommand, "RunRequest.command"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "RunRequest.cwd"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "RunRequest.key"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "RunRequest.name"));
        }
        Object rawNewWorkspace = Wire.optional(object, "new_workspace");
        if (!Wire.isMissing(rawNewWorkspace)) {
            builder.newWorkspace(Wire.bool(rawNewWorkspace, "RunRequest.new_workspace"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "RunRequest.pane"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "RunRequest.rows"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "argv", argv);
        Wire.put(object, "cols", cols);
        Wire.put(object, "command", command);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "key", key);
        Wire.put(object, "name", name);
        Wire.put(object, "new_workspace", newWorkspace);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RunRequest that)) return false;
        return Objects.equals(argv, that.argv) && Objects.equals(cols, that.cols) && Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd) && Objects.equals(key, that.key) && Objects.equals(name, that.name) && Objects.equals(newWorkspace, that.newWorkspace) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(argv, cols, command, cwd, key, name, newWorkspace, pane, rows); }

    @Override
    public String toString() { return "RunRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> argv = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private Field<String> command = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<Boolean> newWorkspace = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<Integer> rows = Field.omitted();

        public Builder argv(List<String> value) {
            this.argv = Field.ofNullable(value);
            return this;
        }
        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder command(String value) {
            this.command = Field.ofNullable(value);
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder newWorkspace(Boolean value) {
            this.newWorkspace = Field.of(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public RunRequest build() { return new RunRequest(this); }
    }
}

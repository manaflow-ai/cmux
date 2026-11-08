// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-terminal request. Protocol v7; authority: control. */
public final class CreateTerminalRequest implements WireValue {
    private final Field<List<String>> argv;
    private final Field<Integer> cols;
    private final Field<String> command;
    private final Field<String> cwd;
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    private final Field<String> key;
    private final Field<String> mutationId;
    private final Field<String> name;
    private final Field<String> origin;
    private final Field<Integer> rows;
    private final Field<String> terminalId;
    private final Field<UInt64> workspace;

    private CreateTerminalRequest(Builder builder) {
        this.argv = builder.argv.map(value -> List.copyOf(value));
        this.cols = builder.cols;
        this.command = builder.command;
        this.cwd = builder.cwd;
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.key = builder.key;
        this.mutationId = builder.mutationId;
        this.name = builder.name;
        this.origin = builder.origin;
        this.rows = builder.rows;
        this.terminalId = builder.terminalId;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> argv() { return argv; }
    public Field<Integer> cols() { return cols; }
    public Field<String> command() { return command; }
    public Field<String> cwd() { return cwd; }
    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> key() { return key; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> name() { return name; }
    public Field<String> origin() { return origin; }
    public Field<Integer> rows() { return rows; }
    public Field<String> terminalId() { return terminalId; }
    public Field<UInt64> workspace() { return workspace; }

    public static CreateTerminalRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateTerminalRequest");
        Builder builder = builder();
        Object rawArgv = Wire.optional(object, "argv");
        if (!Wire.isMissing(rawArgv)) {
            builder.argv(rawArgv == null ? null : Wire.array(rawArgv, "CreateTerminalRequest.argv", item -> Wire.string(item, "CreateTerminalRequest.argv item")));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "CreateTerminalRequest.cols"));
        }
        Object rawCommand = Wire.optional(object, "command");
        if (!Wire.isMissing(rawCommand)) {
            builder.command(rawCommand == null ? null : Wire.string(rawCommand, "CreateTerminalRequest.command"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "CreateTerminalRequest.cwd"));
        }
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "CreateTerminalRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "CreateTerminalRequest.expected_revision"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "CreateTerminalRequest.key"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "CreateTerminalRequest.mutation_id"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "CreateTerminalRequest.name"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CreateTerminalRequest.origin"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "CreateTerminalRequest.rows"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "CreateTerminalRequest.terminal_id"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "CreateTerminalRequest.workspace"));
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
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "key", key);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "name", name);
        Wire.put(object, "origin", origin);
        Wire.put(object, "rows", rows);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateTerminalRequest that)) return false;
        return Objects.equals(argv, that.argv) && Objects.equals(cols, that.cols) && Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd) && Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(key, that.key) && Objects.equals(mutationId, that.mutationId) && Objects.equals(name, that.name) && Objects.equals(origin, that.origin) && Objects.equals(rows, that.rows) && Objects.equals(terminalId, that.terminalId) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(argv, cols, command, cwd, expectedGeneration, expectedRevision, key, mutationId, name, origin, rows, terminalId, workspace); }

    @Override
    public String toString() { return "CreateTerminalRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> argv = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private Field<String> command = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

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
        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.ofNullable(value);
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public CreateTerminalRequest build() { return new CreateTerminalRequest(this); }
    }
}

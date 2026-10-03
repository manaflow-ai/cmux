// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-row request. Protocol v12; authority: control. */
public final class NewRowRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<String> cwd;
    private final Field<Map<String, String>> env;
    private final UInt64 heightPermille;
    private final Field<Boolean> keep;
    private final UInt64 pane;
    private final Field<Integer> rows;
    private final Field<List<String>> shellArgs;
    private final Field<String> terminalId;
    private final Field<String> transaction;

    private NewRowRequest(Builder builder) {
        this.cols = builder.cols;
        this.cwd = builder.cwd;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        if (!builder.heightPermilleSet) throw new IllegalArgumentException("height_permille is required");
        this.heightPermille = Wire.nonNull(builder.heightPermille, "height_permille");
        this.keep = builder.keep;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
        this.shellArgs = builder.shellArgs.map(value -> List.copyOf(value));
        this.terminalId = builder.terminalId;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<String> cwd() { return cwd; }
    public Field<Map<String, String>> env() { return env; }
    public UInt64 heightPermille() { return heightPermille; }
    public Field<Boolean> keep() { return keep; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public Field<List<String>> shellArgs() { return shellArgs; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> transaction() { return transaction; }

    public static NewRowRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewRowRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewRowRequest.cols"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "NewRowRequest.cwd"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "NewRowRequest.env", item -> Wire.string(item, "NewRowRequest.env value")));
        }
        Object rawHeightPermille = Wire.required(object, "height_permille");
        builder.heightPermille(Wire.uint64(rawHeightPermille, "NewRowRequest.height_permille"));
        Object rawKeep = Wire.optional(object, "keep");
        if (!Wire.isMissing(rawKeep)) {
            builder.keep(Wire.bool(rawKeep, "NewRowRequest.keep"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "NewRowRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewRowRequest.rows"));
        }
        Object rawShellArgs = Wire.optional(object, "shell_args");
        if (!Wire.isMissing(rawShellArgs)) {
            builder.shellArgs(rawShellArgs == null ? null : Wire.array(rawShellArgs, "NewRowRequest.shell_args", item -> Wire.string(item, "NewRowRequest.shell_args item")));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "NewRowRequest.terminal_id"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "NewRowRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "env", env);
        Wire.put(object, "height_permille", heightPermille);
        Wire.put(object, "keep", keep);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "shell_args", shellArgs);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewRowRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(cwd, that.cwd) && Objects.equals(env, that.env) && Objects.equals(heightPermille, that.heightPermille) && Objects.equals(keep, that.keep) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(shellArgs, that.shellArgs) && Objects.equals(terminalId, that.terminalId) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, cwd, env, heightPermille, keep, pane, rows, shellArgs, terminalId, transaction); }

    @Override
    public String toString() { return "NewRowRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private UInt64 heightPermille;
        private boolean heightPermilleSet;
        private Field<Boolean> keep = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();
        private Field<List<String>> shellArgs = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> transaction = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder env(Map<String, String> value) {
            this.env = Field.ofNullable(value);
            return this;
        }
        public Builder heightPermille(UInt64 value) {
            this.heightPermille = value;
            this.heightPermilleSet = true;
            return this;
        }
        public Builder keep(Boolean value) {
            this.keep = Field.of(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder shellArgs(List<String> value) {
            this.shellArgs = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public NewRowRequest build() { return new NewRowRequest(this); }
    }
}

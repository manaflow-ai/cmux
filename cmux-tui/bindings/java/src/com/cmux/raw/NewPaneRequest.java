// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-pane request. Protocol v9; authority: control. */
public final class NewPaneRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<String> cwd;
    private final Field<Map<String, String>> env;
    private final Field<Boolean> keep;
    private final UInt64 pane;
    private final Field<Integer> rows;
    private final Field<String> terminalId;

    private NewPaneRequest(Builder builder) {
        this.cols = builder.cols;
        this.cwd = builder.cwd;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        this.keep = builder.keep;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<String> cwd() { return cwd; }
    public Field<Map<String, String>> env() { return env; }
    public Field<Boolean> keep() { return keep; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public Field<String> terminalId() { return terminalId; }

    public static NewPaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewPaneRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewPaneRequest.cols"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "NewPaneRequest.cwd"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "NewPaneRequest.env", item -> Wire.string(item, "NewPaneRequest.env value")));
        }
        Object rawKeep = Wire.optional(object, "keep");
        if (!Wire.isMissing(rawKeep)) {
            builder.keep(Wire.bool(rawKeep, "NewPaneRequest.keep"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "NewPaneRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewPaneRequest.rows"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "NewPaneRequest.terminal_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "env", env);
        Wire.put(object, "keep", keep);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewPaneRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(cwd, that.cwd) && Objects.equals(env, that.env) && Objects.equals(keep, that.keep) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, cwd, env, keep, pane, rows, terminalId); }

    @Override
    public String toString() { return "NewPaneRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private Field<Boolean> keep = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();
        private Field<String> terminalId = Field.omitted();

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
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public NewPaneRequest build() { return new NewPaneRequest(this); }
    }
}

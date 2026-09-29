// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-tab request. Protocol v5; authority: control. */
public final class NewTabRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<String> cwd;
    private final Field<Map<String, String>> env;
    private final Field<UInt64> pane;
    private final Field<Integer> rows;

    private NewTabRequest(Builder builder) {
        this.cols = builder.cols;
        this.cwd = builder.cwd;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        this.pane = builder.pane;
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<String> cwd() { return cwd; }
    public Field<Map<String, String>> env() { return env; }
    public Field<UInt64> pane() { return pane; }
    public Field<Integer> rows() { return rows; }

    public static NewTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewTabRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewTabRequest.cols"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "NewTabRequest.cwd"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "NewTabRequest.env", item -> Wire.string(item, "NewTabRequest.env value")));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewTabRequest.pane"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewTabRequest.rows"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "env", env);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewTabRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(cwd, that.cwd) && Objects.equals(env, that.env) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, cwd, env, pane, rows); }

    @Override
    public String toString() { return "NewTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<Integer> rows = Field.omitted();

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
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public NewTabRequest build() { return new NewTabRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-screen request. Protocol v5; authority: control. */
public final class NewScreenRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<Integer> rows;
    private final Field<UInt64> workspace;

    private NewScreenRequest(Builder builder) {
        this.cols = builder.cols;
        this.rows = builder.rows;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<Integer> rows() { return rows; }
    public Field<UInt64> workspace() { return workspace; }

    public static NewScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewScreenRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewScreenRequest.cols"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewScreenRequest.rows"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "NewScreenRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "rows", rows);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewScreenRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(rows, that.rows) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, rows, workspace); }

    @Override
    public String toString() { return "NewScreenRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public NewScreenRequest build() { return new NewScreenRequest(this); }
    }
}

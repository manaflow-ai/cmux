// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-workspace request. Protocol v5; authority: control. */
public final class NewWorkspaceRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<String> name;
    private final Field<Integer> rows;

    private NewWorkspaceRequest(Builder builder) {
        this.cols = builder.cols;
        this.name = builder.name;
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<String> name() { return name; }
    public Field<Integer> rows() { return rows; }

    public static NewWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewWorkspaceRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewWorkspaceRequest.cols"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "NewWorkspaceRequest.name"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewWorkspaceRequest.rows"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "name", name);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewWorkspaceRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(name, that.name) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, name, rows); }

    @Override
    public String toString() { return "NewWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<Integer> rows = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public NewWorkspaceRequest build() { return new NewWorkspaceRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apply-layout request. Protocol v6; authority: control. */
public final class ApplyLayoutRequest implements WireValue {
    private final Field<Integer> cols;
    private final DeclarativeLayout layout;
    private final Field<String> name;
    private final Field<Integer> rows;
    private final Field<UInt64> workspace;

    private ApplyLayoutRequest(Builder builder) {
        this.cols = builder.cols;
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        this.name = builder.name;
        this.rows = builder.rows;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public DeclarativeLayout layout() { return layout; }
    public Field<String> name() { return name; }
    public Field<Integer> rows() { return rows; }
    public Field<UInt64> workspace() { return workspace; }

    public static ApplyLayoutRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ApplyLayoutRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "ApplyLayoutRequest.cols"));
        }
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(DeclarativeLayout.fromWire(rawLayout));
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "ApplyLayoutRequest.name"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "ApplyLayoutRequest.rows"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "ApplyLayoutRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "layout", layout);
        Wire.put(object, "name", name);
        Wire.put(object, "rows", rows);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ApplyLayoutRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(layout, that.layout) && Objects.equals(name, that.name) && Objects.equals(rows, that.rows) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, layout, name, rows, workspace); }

    @Override
    public String toString() { return "ApplyLayoutRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private DeclarativeLayout layout;
        private boolean layoutSet;
        private Field<String> name = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder layout(DeclarativeLayout value) {
            this.layout = value;
            this.layoutSet = true;
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
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public ApplyLayoutRequest build() { return new ApplyLayoutRequest(this); }
    }
}

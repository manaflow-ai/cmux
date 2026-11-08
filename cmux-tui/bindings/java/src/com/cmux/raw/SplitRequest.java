// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable split request. Protocol v5; authority: control. */
public final class SplitRequest implements WireValue {
    private final Field<Integer> cols;
    private final SplitDirection dir;
    private final UInt64 pane;
    private final Field<Integer> rows;

    private SplitRequest(Builder builder) {
        this.cols = builder.cols;
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public SplitDirection dir() { return dir; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }

    public static SplitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SplitRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "SplitRequest.cols"));
        }
        Object rawDir = Wire.required(object, "dir");
        builder.dir(SplitDirection.fromWire(rawDir));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SplitRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "SplitRequest.rows"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "dir", dir);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SplitRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(dir, that.dir) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, dir, pane, rows); }

    @Override
    public String toString() { return "SplitRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private SplitDirection dir;
        private boolean dirSet;
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder dir(SplitDirection value) {
            this.dir = value;
            this.dirSet = true;
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
        public SplitRequest build() { return new SplitRequest(this); }
    }
}

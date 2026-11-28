// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-pane-right request. Protocol v9; authority: control. */
public final class NewPaneRightRequest implements WireValue {
    private final Field<Integer> cols;
    private final UInt64 pane;
    private final Field<Integer> rows;
    private final Field<Double> width;

    private NewPaneRightRequest(Builder builder) {
        this.cols = builder.cols;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public Field<Double> width() { return width; }

    public static NewPaneRightRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewPaneRightRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewPaneRightRequest.cols"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "NewPaneRightRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewPaneRightRequest.rows"));
        }
        Object rawWidth = Wire.optional(object, "width");
        if (!Wire.isMissing(rawWidth)) {
            builder.width(rawWidth == null ? null : Wire.float64(rawWidth, "NewPaneRightRequest.width"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewPaneRightRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, pane, rows, width); }

    @Override
    public String toString() { return "NewPaneRightRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();
        private Field<Double> width = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
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
        public Builder width(Double value) {
            this.width = Field.ofNullable(value);
            return this;
        }
        public NewPaneRightRequest build() { return new NewPaneRightRequest(this); }
    }
}

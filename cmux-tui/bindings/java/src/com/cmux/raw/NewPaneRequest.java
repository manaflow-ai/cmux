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
    private final UInt64 pane;
    private final Field<Integer> rows;

    private NewPaneRequest(Builder builder) {
        this.cols = builder.cols;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }

    public static NewPaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewPaneRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewPaneRequest.cols"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "NewPaneRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewPaneRequest.rows"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewPaneRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, pane, rows); }

    @Override
    public String toString() { return "NewPaneRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();

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
        public NewPaneRequest build() { return new NewPaneRequest(this); }
    }
}

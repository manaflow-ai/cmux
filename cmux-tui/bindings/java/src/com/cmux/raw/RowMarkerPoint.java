// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RowMarkerPoint implements WireValue {
    private final int col;
    private final UInt64 rowMarker;

    private RowMarkerPoint(Builder builder) {
        if (!builder.colSet) throw new IllegalArgumentException("col is required");
        this.col = builder.col;
        if (!builder.rowMarkerSet) throw new IllegalArgumentException("row_marker is required");
        this.rowMarker = Wire.nonNull(builder.rowMarker, "row_marker");
    }

    public static Builder builder() { return new Builder(); }

    public int col() { return col; }
    public UInt64 rowMarker() { return rowMarker; }

    public static RowMarkerPoint fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RowMarkerPoint");
        Builder builder = builder();
        Object rawCol = Wire.required(object, "col");
        builder.col(Wire.uint16(rawCol, "RowMarkerPoint.col"));
        Object rawRowMarker = Wire.required(object, "row_marker");
        builder.rowMarker(Wire.uint64(rawRowMarker, "RowMarkerPoint.row_marker"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "col", col);
        Wire.put(object, "row_marker", rowMarker);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RowMarkerPoint that)) return false;
        return Objects.equals(col, that.col) && Objects.equals(rowMarker, that.rowMarker);
    }

    @Override
    public int hashCode() { return Objects.hash(col, rowMarker); }

    @Override
    public String toString() { return "RowMarkerPoint" + toWire(); }

    public static final class Builder {
        private Integer col;
        private boolean colSet;
        private UInt64 rowMarker;
        private boolean rowMarkerSet;

        public Builder col(int value) {
            this.col = value;
            this.colSet = true;
            return this;
        }
        public Builder rowMarker(UInt64 value) {
            this.rowMarker = value;
            this.rowMarkerSet = true;
            return this;
        }
        public RowMarkerPoint build() { return new RowMarkerPoint(this); }
    }
}

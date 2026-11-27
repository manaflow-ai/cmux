// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RowHeight implements WireValue {
    private final UInt64 height;
    private final UInt64 row;

    private RowHeight(Builder builder) {
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = Wire.nonNull(builder.height, "height");
        if (!builder.rowSet) throw new IllegalArgumentException("row is required");
        this.row = Wire.nonNull(builder.row, "row");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 height() { return height; }
    public UInt64 row() { return row; }

    public static RowHeight fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RowHeight");
        Builder builder = builder();
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint64(rawHeight, "RowHeight.height"));
        Object rawRow = Wire.required(object, "row");
        builder.row(Wire.uint64(rawRow, "RowHeight.row"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "height", height);
        Wire.put(object, "row", row);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RowHeight that)) return false;
        return Objects.equals(height, that.height) && Objects.equals(row, that.row);
    }

    @Override
    public int hashCode() { return Objects.hash(height, row); }

    @Override
    public String toString() { return "RowHeight" + toWire(); }

    public static final class Builder {
        private UInt64 height;
        private boolean heightSet;
        private UInt64 row;
        private boolean rowSet;

        public Builder height(UInt64 value) {
            this.height = value;
            this.heightSet = true;
            return this;
        }
        public Builder row(UInt64 value) {
            this.row = value;
            this.rowSet = true;
            return this;
        }
        public RowHeight build() { return new RowHeight(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable resize-surface request. Protocol v5; authority: control. */
public final class ResizeSurfaceRequest implements WireValue {
    private final int cols;
    private final int rows;
    private final UInt64 surface;

    private ResizeSurfaceRequest(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public int rows() { return rows; }
    public UInt64 surface() { return surface; }

    public static ResizeSurfaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResizeSurfaceRequest");
        Builder builder = builder();
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "ResizeSurfaceRequest.cols"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "ResizeSurfaceRequest.rows"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ResizeSurfaceRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "rows", rows);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResizeSurfaceRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(rows, that.rows) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, rows, surface); }

    @Override
    public String toString() { return "ResizeSurfaceRequest" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private Integer rows;
        private boolean rowsSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ResizeSurfaceRequest build() { return new ResizeSurfaceRequest(this); }
    }
}

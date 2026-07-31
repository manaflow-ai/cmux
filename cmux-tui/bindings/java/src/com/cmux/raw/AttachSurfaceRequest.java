// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable attach-surface request. Protocol v5; authority: frontend. */
public final class AttachSurfaceRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<AttachSurfaceRequestMode> mode;
    private final Field<Integer> rows;
    private final UInt64 surface;

    private AttachSurfaceRequest(Builder builder) {
        this.cols = builder.cols;
        this.mode = builder.mode;
        this.rows = builder.rows;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<AttachSurfaceRequestMode> mode() { return mode; }
    public Field<Integer> rows() { return rows; }
    public UInt64 surface() { return surface; }

    public static AttachSurfaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AttachSurfaceRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "AttachSurfaceRequest.cols"));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : AttachSurfaceRequestMode.fromWire(rawMode));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "AttachSurfaceRequest.rows"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AttachSurfaceRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "mode", mode);
        Wire.put(object, "rows", rows);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AttachSurfaceRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(mode, that.mode) && Objects.equals(rows, that.rows) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, mode, rows, surface); }

    @Override
    public String toString() { return "AttachSurfaceRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<AttachSurfaceRequestMode> mode = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder mode(AttachSurfaceRequestMode value) {
            this.mode = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AttachSurfaceRequest build() { return new AttachSurfaceRequest(this); }
    }
}

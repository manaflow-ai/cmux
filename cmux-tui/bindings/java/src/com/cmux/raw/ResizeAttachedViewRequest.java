// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable resize-attached-view request. Protocol v10; authority: frontend. */
public final class ResizeAttachedViewRequest implements WireValue {
    private final int cols;
    private final Field<SizingIdentity> identity;
    private final Field<String> lease;
    private final int rows;
    private final UInt64 surface;
    private final Field<String> view;

    private ResizeAttachedViewRequest(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        this.identity = builder.identity;
        this.lease = builder.lease;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.view = builder.view;
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public Field<SizingIdentity> identity() { return identity; }
    public Field<String> lease() { return lease; }
    public int rows() { return rows; }
    public UInt64 surface() { return surface; }
    public Field<String> view() { return view; }

    public static ResizeAttachedViewRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResizeAttachedViewRequest");
        Builder builder = builder();
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "ResizeAttachedViewRequest.cols"));
        Object rawIdentity = Wire.optional(object, "identity");
        if (!Wire.isMissing(rawIdentity)) {
            builder.identity(rawIdentity == null ? null : SizingIdentity.fromWire(rawIdentity));
        }
        Object rawLease = Wire.optional(object, "lease");
        if (!Wire.isMissing(rawLease)) {
            builder.lease(rawLease == null ? null : Wire.string(rawLease, "ResizeAttachedViewRequest.lease"));
        }
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "ResizeAttachedViewRequest.rows"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ResizeAttachedViewRequest.surface"));
        Object rawView = Wire.optional(object, "view");
        if (!Wire.isMissing(rawView)) {
            builder.view(rawView == null ? null : Wire.string(rawView, "ResizeAttachedViewRequest.view"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "identity", identity);
        Wire.put(object, "lease", lease);
        Wire.put(object, "rows", rows);
        Wire.put(object, "surface", surface);
        Wire.put(object, "view", view);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResizeAttachedViewRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(identity, that.identity) && Objects.equals(lease, that.lease) && Objects.equals(rows, that.rows) && Objects.equals(surface, that.surface) && Objects.equals(view, that.view);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, identity, lease, rows, surface, view); }

    @Override
    public String toString() { return "ResizeAttachedViewRequest" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private Field<SizingIdentity> identity = Field.omitted();
        private Field<String> lease = Field.omitted();
        private Integer rows;
        private boolean rowsSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> view = Field.omitted();

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder identity(SizingIdentity value) {
            this.identity = Field.ofNullable(value);
            return this;
        }
        public Builder lease(String value) {
            this.lease = Field.ofNullable(value);
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
        public Builder view(String value) {
            this.view = Field.ofNullable(value);
            return this;
        }
        public ResizeAttachedViewRequest build() { return new ResizeAttachedViewRequest(this); }
    }
}

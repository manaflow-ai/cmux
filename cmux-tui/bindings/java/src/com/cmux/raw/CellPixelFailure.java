// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CellPixelFailure implements WireValue {
    private final String error;
    private final UInt64 surface;

    private CellPixelFailure(Builder builder) {
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = Wire.nonNull(builder.error, "error");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String error() { return error; }
    public UInt64 surface() { return surface; }

    public static CellPixelFailure fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CellPixelFailure");
        Builder builder = builder();
        Object rawError = Wire.required(object, "error");
        builder.error(Wire.string(rawError, "CellPixelFailure.error"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "CellPixelFailure.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "error", error);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CellPixelFailure that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(error, surface); }

    @Override
    public String toString() { return "CellPixelFailure" + toWire(); }

    public static final class Builder {
        private String error;
        private boolean errorSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public CellPixelFailure build() { return new CellPixelFailure(this); }
    }
}

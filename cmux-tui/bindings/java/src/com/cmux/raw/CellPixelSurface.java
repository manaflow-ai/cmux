// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CellPixelSurface implements WireValue {
    private final int heightPx;
    private final UInt64 surface;
    private final int widthPx;

    private CellPixelSurface(Builder builder) {
        if (!builder.heightPxSet) throw new IllegalArgumentException("height_px is required");
        this.heightPx = builder.heightPx;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.widthPxSet) throw new IllegalArgumentException("width_px is required");
        this.widthPx = builder.widthPx;
    }

    public static Builder builder() { return new Builder(); }

    public int heightPx() { return heightPx; }
    public UInt64 surface() { return surface; }
    public int widthPx() { return widthPx; }

    public static CellPixelSurface fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CellPixelSurface");
        Builder builder = builder();
        Object rawHeightPx = Wire.required(object, "height_px");
        builder.heightPx(Wire.uint16(rawHeightPx, "CellPixelSurface.height_px"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "CellPixelSurface.surface"));
        Object rawWidthPx = Wire.required(object, "width_px");
        builder.widthPx(Wire.uint16(rawWidthPx, "CellPixelSurface.width_px"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "height_px", heightPx);
        Wire.put(object, "surface", surface);
        Wire.put(object, "width_px", widthPx);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CellPixelSurface that)) return false;
        return Objects.equals(heightPx, that.heightPx) && Objects.equals(surface, that.surface) && Objects.equals(widthPx, that.widthPx);
    }

    @Override
    public int hashCode() { return Objects.hash(heightPx, surface, widthPx); }

    @Override
    public String toString() { return "CellPixelSurface" + toWire(); }

    public static final class Builder {
        private Integer heightPx;
        private boolean heightPxSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Integer widthPx;
        private boolean widthPxSet;

        public Builder heightPx(int value) {
            this.heightPx = value;
            this.heightPxSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder widthPx(int value) {
            this.widthPx = value;
            this.widthPxSet = true;
            return this;
        }
        public CellPixelSurface build() { return new CellPixelSurface(this); }
    }
}

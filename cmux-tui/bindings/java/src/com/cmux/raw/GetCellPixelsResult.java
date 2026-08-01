// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GetCellPixelsResult implements WireValue {
    private final int heightPx;
    private final List<CellPixelSurface> surfaces;
    private final int widthPx;

    private GetCellPixelsResult(Builder builder) {
        if (!builder.heightPxSet) throw new IllegalArgumentException("height_px is required");
        this.heightPx = builder.heightPx;
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        if (!builder.widthPxSet) throw new IllegalArgumentException("width_px is required");
        this.widthPx = builder.widthPx;
    }

    public static Builder builder() { return new Builder(); }

    public int heightPx() { return heightPx; }
    public List<CellPixelSurface> surfaces() { return surfaces; }
    public int widthPx() { return widthPx; }

    public static GetCellPixelsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetCellPixelsResult");
        Builder builder = builder();
        Object rawHeightPx = Wire.required(object, "height_px");
        builder.heightPx(Wire.uint16(rawHeightPx, "GetCellPixelsResult.height_px"));
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "GetCellPixelsResult.surfaces", item -> CellPixelSurface.fromWire(item)));
        Object rawWidthPx = Wire.required(object, "width_px");
        builder.widthPx(Wire.uint16(rawWidthPx, "GetCellPixelsResult.width_px"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "height_px", heightPx);
        Wire.put(object, "surfaces", surfaces);
        Wire.put(object, "width_px", widthPx);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetCellPixelsResult that)) return false;
        return Objects.equals(heightPx, that.heightPx) && Objects.equals(surfaces, that.surfaces) && Objects.equals(widthPx, that.widthPx);
    }

    @Override
    public int hashCode() { return Objects.hash(heightPx, surfaces, widthPx); }

    @Override
    public String toString() { return "GetCellPixelsResult" + toWire(); }

    public static final class Builder {
        private Integer heightPx;
        private boolean heightPxSet;
        private List<CellPixelSurface> surfaces;
        private boolean surfacesSet;
        private Integer widthPx;
        private boolean widthPxSet;

        public Builder heightPx(int value) {
            this.heightPx = value;
            this.heightPxSet = true;
            return this;
        }
        public Builder surfaces(List<CellPixelSurface> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder widthPx(int value) {
            this.widthPx = value;
            this.widthPxSet = true;
            return this;
        }
        public GetCellPixelsResult build() { return new GetCellPixelsResult(this); }
    }
}

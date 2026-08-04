// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-cell-pixels request. Protocol v6; authority: frontend. */
public final class SetCellPixelsRequest implements WireValue {
    private final int heightPx;
    private final int widthPx;

    private SetCellPixelsRequest(Builder builder) {
        if (!builder.heightPxSet) throw new IllegalArgumentException("height_px is required");
        this.heightPx = builder.heightPx;
        if (!builder.widthPxSet) throw new IllegalArgumentException("width_px is required");
        this.widthPx = builder.widthPx;
    }

    public static Builder builder() { return new Builder(); }

    public int heightPx() { return heightPx; }
    public int widthPx() { return widthPx; }

    public static SetCellPixelsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetCellPixelsRequest");
        Builder builder = builder();
        Object rawHeightPx = Wire.required(object, "height_px");
        builder.heightPx(Wire.uint16(rawHeightPx, "SetCellPixelsRequest.height_px"));
        Object rawWidthPx = Wire.required(object, "width_px");
        builder.widthPx(Wire.uint16(rawWidthPx, "SetCellPixelsRequest.width_px"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "height_px", heightPx);
        Wire.put(object, "width_px", widthPx);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetCellPixelsRequest that)) return false;
        return Objects.equals(heightPx, that.heightPx) && Objects.equals(widthPx, that.widthPx);
    }

    @Override
    public int hashCode() { return Objects.hash(heightPx, widthPx); }

    @Override
    public String toString() { return "SetCellPixelsRequest" + toWire(); }

    public static final class Builder {
        private Integer heightPx;
        private boolean heightPxSet;
        private Integer widthPx;
        private boolean widthPxSet;

        public Builder heightPx(int value) {
            this.heightPx = value;
            this.heightPxSet = true;
            return this;
        }
        public Builder widthPx(int value) {
            this.widthPx = value;
            this.widthPxSet = true;
            return this;
        }
        public SetCellPixelsRequest build() { return new SetCellPixelsRequest(this); }
    }
}

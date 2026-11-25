// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutSizePaneWidth implements WireValue {
    private final UInt64 pane;
    private final double width;

    private LayoutSizePaneWidth(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public double width() { return width; }

    public static LayoutSizePaneWidth fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutSizePaneWidth");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "LayoutSizePaneWidth.pane"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "LayoutSizePaneWidth.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutSizePaneWidth that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, width); }

    @Override
    public String toString() { return "LayoutSizePaneWidth" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private Double width;
        private boolean widthSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public LayoutSizePaneWidth build() { return new LayoutSizePaneWidth(this); }
    }
}

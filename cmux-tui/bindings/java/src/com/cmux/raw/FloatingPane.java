// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FloatingPane implements WireValue {
    /** The height, 0 to 1. */
    private final double h;
    /** floating-panes-v1: the pane, still a leaf of the screen's layout; x, y, w and h are its frame as fractions of the screen's pane area. */
    private final UInt64 pane;
    /** The width, 0 to 1. */
    private final double w;
    /** The left edge, 0 to 1. */
    private final double x;
    /** The top edge, 0 to 1. */
    private final double y;

    private FloatingPane(Builder builder) {
        if (!builder.hSet) throw new IllegalArgumentException("h is required");
        this.h = builder.h;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.wSet) throw new IllegalArgumentException("w is required");
        this.w = builder.w;
        if (!builder.xSet) throw new IllegalArgumentException("x is required");
        this.x = builder.x;
        if (!builder.ySet) throw new IllegalArgumentException("y is required");
        this.y = builder.y;
    }

    public static Builder builder() { return new Builder(); }

    public double h() { return h; }
    public UInt64 pane() { return pane; }
    public double w() { return w; }
    public double x() { return x; }
    public double y() { return y; }

    public static FloatingPane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FloatingPane");
        Builder builder = builder();
        Object rawH = Wire.required(object, "h");
        builder.h(Wire.float64(rawH, "FloatingPane.h"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "FloatingPane.pane"));
        Object rawW = Wire.required(object, "w");
        builder.w(Wire.float64(rawW, "FloatingPane.w"));
        Object rawX = Wire.required(object, "x");
        builder.x(Wire.float64(rawX, "FloatingPane.x"));
        Object rawY = Wire.required(object, "y");
        builder.y(Wire.float64(rawY, "FloatingPane.y"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "h", h);
        Wire.put(object, "pane", pane);
        Wire.put(object, "w", w);
        Wire.put(object, "x", x);
        Wire.put(object, "y", y);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FloatingPane that)) return false;
        return Objects.equals(h, that.h) && Objects.equals(pane, that.pane) && Objects.equals(w, that.w) && Objects.equals(x, that.x) && Objects.equals(y, that.y);
    }

    @Override
    public int hashCode() { return Objects.hash(h, pane, w, x, y); }

    @Override
    public String toString() { return "FloatingPane" + toWire(); }

    public static final class Builder {
        private Double h;
        private boolean hSet;
        private UInt64 pane;
        private boolean paneSet;
        private Double w;
        private boolean wSet;
        private Double x;
        private boolean xSet;
        private Double y;
        private boolean ySet;

        public Builder h(double value) {
            this.h = value;
            this.hSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder w(double value) {
            this.w = value;
            this.wSet = true;
            return this;
        }
        public Builder x(double value) {
            this.x = value;
            this.xSet = true;
            return this;
        }
        public Builder y(double value) {
            this.y = value;
            this.ySet = true;
            return this;
        }
        public FloatingPane build() { return new FloatingPane(this); }
    }
}

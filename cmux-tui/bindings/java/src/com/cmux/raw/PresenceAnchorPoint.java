// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PresenceAnchorPoint implements WireValue, PresenceAnchor {
    private final double x;
    private final double y;

    private PresenceAnchorPoint(Builder builder) {
        if (!builder.xSet) throw new IllegalArgumentException("x is required");
        this.x = builder.x;
        if (!builder.ySet) throw new IllegalArgumentException("y is required");
        this.y = builder.y;
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return "point"; }
    public double x() { return x; }
    public double y() { return y; }

    public static PresenceAnchorPoint fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceAnchorPoint");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "point", "PresenceAnchorPoint.kind");
        Object rawX = Wire.required(object, "x");
        builder.x(Wire.float64(rawX, "PresenceAnchorPoint.x"));
        Object rawY = Wire.required(object, "y");
        builder.y(Wire.float64(rawY, "PresenceAnchorPoint.y"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", "point");
        Wire.put(object, "x", x);
        Wire.put(object, "y", y);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PresenceAnchorPoint that)) return false;
        return Objects.equals(x, that.x) && Objects.equals(y, that.y);
    }

    @Override
    public int hashCode() { return Objects.hash(x, y); }

    @Override
    public String toString() { return "PresenceAnchorPoint" + toWire(); }

    public static final class Builder {
        private Double x;
        private boolean xSet;
        private Double y;
        private boolean ySet;

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
        public PresenceAnchorPoint build() { return new PresenceAnchorPoint(this); }
    }
}

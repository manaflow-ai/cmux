// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-wheel request. Protocol v6; authority: frontend. */
public final class BrowserWheelRequest implements WireValue {
    private final double deltaYPx;
    private final Field<UInt64> frameSeq;
    private final UInt64 surface;
    private final double xPx;
    private final double yPx;

    private BrowserWheelRequest(Builder builder) {
        if (!builder.deltaYPxSet) throw new IllegalArgumentException("delta_y_px is required");
        this.deltaYPx = builder.deltaYPx;
        this.frameSeq = builder.frameSeq;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.xPxSet) throw new IllegalArgumentException("x_px is required");
        this.xPx = builder.xPx;
        if (!builder.yPxSet) throw new IllegalArgumentException("y_px is required");
        this.yPx = builder.yPx;
    }

    public static Builder builder() { return new Builder(); }

    public double deltaYPx() { return deltaYPx; }
    public Field<UInt64> frameSeq() { return frameSeq; }
    public UInt64 surface() { return surface; }
    public double xPx() { return xPx; }
    public double yPx() { return yPx; }

    public static BrowserWheelRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserWheelRequest");
        Builder builder = builder();
        Object rawDeltaYPx = Wire.required(object, "delta_y_px");
        builder.deltaYPx(Wire.float64(rawDeltaYPx, "BrowserWheelRequest.delta_y_px"));
        Object rawFrameSeq = Wire.optional(object, "frame_seq");
        if (!Wire.isMissing(rawFrameSeq)) {
            builder.frameSeq(rawFrameSeq == null ? null : Wire.uint64(rawFrameSeq, "BrowserWheelRequest.frame_seq"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserWheelRequest.surface"));
        Object rawXPx = Wire.required(object, "x_px");
        builder.xPx(Wire.float64(rawXPx, "BrowserWheelRequest.x_px"));
        Object rawYPx = Wire.required(object, "y_px");
        builder.yPx(Wire.float64(rawYPx, "BrowserWheelRequest.y_px"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "delta_y_px", deltaYPx);
        Wire.put(object, "frame_seq", frameSeq);
        Wire.put(object, "surface", surface);
        Wire.put(object, "x_px", xPx);
        Wire.put(object, "y_px", yPx);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserWheelRequest that)) return false;
        return Objects.equals(deltaYPx, that.deltaYPx) && Objects.equals(frameSeq, that.frameSeq) && Objects.equals(surface, that.surface) && Objects.equals(xPx, that.xPx) && Objects.equals(yPx, that.yPx);
    }

    @Override
    public int hashCode() { return Objects.hash(deltaYPx, frameSeq, surface, xPx, yPx); }

    @Override
    public String toString() { return "BrowserWheelRequest" + toWire(); }

    public static final class Builder {
        private Double deltaYPx;
        private boolean deltaYPxSet;
        private Field<UInt64> frameSeq = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Double xPx;
        private boolean xPxSet;
        private Double yPx;
        private boolean yPxSet;

        public Builder deltaYPx(double value) {
            this.deltaYPx = value;
            this.deltaYPxSet = true;
            return this;
        }
        public Builder frameSeq(UInt64 value) {
            this.frameSeq = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder xPx(double value) {
            this.xPx = value;
            this.xPxSet = true;
            return this;
        }
        public Builder yPx(double value) {
            this.yPx = value;
            this.yPxSet = true;
            return this;
        }
        public BrowserWheelRequest build() { return new BrowserWheelRequest(this); }
    }
}

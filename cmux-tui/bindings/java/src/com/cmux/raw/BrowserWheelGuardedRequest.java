// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-wheel-guarded request. Protocol v10; authority: frontend. */
public final class BrowserWheelGuardedRequest implements WireValue {
    private final double deltaYPx;
    private final UInt64 frameSeq;
    private final UInt64 surface;
    private final double xPx;
    private final double yPx;

    private BrowserWheelGuardedRequest(Builder builder) {
        if (!builder.deltaYPxSet) throw new IllegalArgumentException("delta_y_px is required");
        this.deltaYPx = builder.deltaYPx;
        if (!builder.frameSeqSet) throw new IllegalArgumentException("frame_seq is required");
        this.frameSeq = Wire.nonNull(builder.frameSeq, "frame_seq");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.xPxSet) throw new IllegalArgumentException("x_px is required");
        this.xPx = builder.xPx;
        if (!builder.yPxSet) throw new IllegalArgumentException("y_px is required");
        this.yPx = builder.yPx;
    }

    public static Builder builder() { return new Builder(); }

    public double deltaYPx() { return deltaYPx; }
    public UInt64 frameSeq() { return frameSeq; }
    public UInt64 surface() { return surface; }
    public double xPx() { return xPx; }
    public double yPx() { return yPx; }

    public static BrowserWheelGuardedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserWheelGuardedRequest");
        Builder builder = builder();
        Object rawDeltaYPx = Wire.required(object, "delta_y_px");
        builder.deltaYPx(Wire.float64(rawDeltaYPx, "BrowserWheelGuardedRequest.delta_y_px"));
        Object rawFrameSeq = Wire.required(object, "frame_seq");
        builder.frameSeq(Wire.uint64(rawFrameSeq, "BrowserWheelGuardedRequest.frame_seq"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserWheelGuardedRequest.surface"));
        Object rawXPx = Wire.required(object, "x_px");
        builder.xPx(Wire.float64(rawXPx, "BrowserWheelGuardedRequest.x_px"));
        Object rawYPx = Wire.required(object, "y_px");
        builder.yPx(Wire.float64(rawYPx, "BrowserWheelGuardedRequest.y_px"));
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
        if (!(other instanceof BrowserWheelGuardedRequest that)) return false;
        return Objects.equals(deltaYPx, that.deltaYPx) && Objects.equals(frameSeq, that.frameSeq) && Objects.equals(surface, that.surface) && Objects.equals(xPx, that.xPx) && Objects.equals(yPx, that.yPx);
    }

    @Override
    public int hashCode() { return Objects.hash(deltaYPx, frameSeq, surface, xPx, yPx); }

    @Override
    public String toString() { return "BrowserWheelGuardedRequest" + toWire(); }

    public static final class Builder {
        private Double deltaYPx;
        private boolean deltaYPxSet;
        private UInt64 frameSeq;
        private boolean frameSeqSet;
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
            this.frameSeq = value;
            this.frameSeqSet = true;
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
        public BrowserWheelGuardedRequest build() { return new BrowserWheelGuardedRequest(this); }
    }
}

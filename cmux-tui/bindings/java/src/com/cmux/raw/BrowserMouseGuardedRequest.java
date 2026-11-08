// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-mouse-guarded request. Protocol v10; authority: frontend. */
public final class BrowserMouseGuardedRequest implements WireValue {
    private final Field<String> button;
    private final Field<Long> clickCount;
    private final UInt64 frameSeq;
    private final BrowserMouseGuardedRequestKind kind;
    private final UInt64 surface;
    private final double xPx;
    private final double yPx;

    private BrowserMouseGuardedRequest(Builder builder) {
        this.button = builder.button;
        this.clickCount = builder.clickCount;
        if (!builder.frameSeqSet) throw new IllegalArgumentException("frame_seq is required");
        this.frameSeq = Wire.nonNull(builder.frameSeq, "frame_seq");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.xPxSet) throw new IllegalArgumentException("x_px is required");
        this.xPx = builder.xPx;
        if (!builder.yPxSet) throw new IllegalArgumentException("y_px is required");
        this.yPx = builder.yPx;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> button() { return button; }
    public Field<Long> clickCount() { return clickCount; }
    public UInt64 frameSeq() { return frameSeq; }
    public BrowserMouseGuardedRequestKind kind() { return kind; }
    public UInt64 surface() { return surface; }
    public double xPx() { return xPx; }
    public double yPx() { return yPx; }

    public static BrowserMouseGuardedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserMouseGuardedRequest");
        Builder builder = builder();
        Object rawButton = Wire.optional(object, "button");
        if (!Wire.isMissing(rawButton)) {
            builder.button(rawButton == null ? null : Wire.string(rawButton, "BrowserMouseGuardedRequest.button"));
        }
        Object rawClickCount = Wire.optional(object, "click_count");
        if (!Wire.isMissing(rawClickCount)) {
            builder.clickCount(rawClickCount == null ? null : Wire.uint32(rawClickCount, "BrowserMouseGuardedRequest.click_count"));
        }
        Object rawFrameSeq = Wire.required(object, "frame_seq");
        builder.frameSeq(Wire.uint64(rawFrameSeq, "BrowserMouseGuardedRequest.frame_seq"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(BrowserMouseGuardedRequestKind.fromWire(rawKind));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserMouseGuardedRequest.surface"));
        Object rawXPx = Wire.required(object, "x_px");
        builder.xPx(Wire.float64(rawXPx, "BrowserMouseGuardedRequest.x_px"));
        Object rawYPx = Wire.required(object, "y_px");
        builder.yPx(Wire.float64(rawYPx, "BrowserMouseGuardedRequest.y_px"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "button", button);
        Wire.put(object, "click_count", clickCount);
        Wire.put(object, "frame_seq", frameSeq);
        Wire.put(object, "kind", kind);
        Wire.put(object, "surface", surface);
        Wire.put(object, "x_px", xPx);
        Wire.put(object, "y_px", yPx);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserMouseGuardedRequest that)) return false;
        return Objects.equals(button, that.button) && Objects.equals(clickCount, that.clickCount) && Objects.equals(frameSeq, that.frameSeq) && Objects.equals(kind, that.kind) && Objects.equals(surface, that.surface) && Objects.equals(xPx, that.xPx) && Objects.equals(yPx, that.yPx);
    }

    @Override
    public int hashCode() { return Objects.hash(button, clickCount, frameSeq, kind, surface, xPx, yPx); }

    @Override
    public String toString() { return "BrowserMouseGuardedRequest" + toWire(); }

    public static final class Builder {
        private Field<String> button = Field.omitted();
        private Field<Long> clickCount = Field.omitted();
        private UInt64 frameSeq;
        private boolean frameSeqSet;
        private BrowserMouseGuardedRequestKind kind;
        private boolean kindSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Double xPx;
        private boolean xPxSet;
        private Double yPx;
        private boolean yPxSet;

        public Builder button(String value) {
            this.button = Field.ofNullable(value);
            return this;
        }
        public Builder clickCount(Long value) {
            this.clickCount = Field.ofNullable(value);
            return this;
        }
        public Builder frameSeq(UInt64 value) {
            this.frameSeq = value;
            this.frameSeqSet = true;
            return this;
        }
        public Builder kind(BrowserMouseGuardedRequestKind value) {
            this.kind = value;
            this.kindSet = true;
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
        public BrowserMouseGuardedRequest build() { return new BrowserMouseGuardedRequest(this); }
    }
}

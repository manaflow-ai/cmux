// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable scroll-surface request. Protocol v5; authority: control. */
public final class ScrollSurfaceRequest implements WireValue {
    private final long delta;
    private final UInt64 surface;

    private ScrollSurfaceRequest(Builder builder) {
        if (!builder.deltaSet) throw new IllegalArgumentException("delta is required");
        this.delta = builder.delta;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public long delta() { return delta; }
    public UInt64 surface() { return surface; }

    public static ScrollSurfaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScrollSurfaceRequest");
        Builder builder = builder();
        Object rawDelta = Wire.required(object, "delta");
        builder.delta(Wire.int64(rawDelta, "ScrollSurfaceRequest.delta"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ScrollSurfaceRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "delta", delta);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScrollSurfaceRequest that)) return false;
        return Objects.equals(delta, that.delta) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(delta, surface); }

    @Override
    public String toString() { return "ScrollSurfaceRequest" + toWire(); }

    public static final class Builder {
        private Long delta;
        private boolean deltaSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder delta(long value) {
            this.delta = value;
            this.deltaSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ScrollSurfaceRequest build() { return new ScrollSurfaceRequest(this); }
    }
}

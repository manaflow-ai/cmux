// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable bell event. Protocol v5; streams: subscribe. */
public final class BellEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 surface;

    private BellEvent(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    @Override public String event() { return "bell"; }

    public static BellEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BellEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "bell", "BellEvent.event");
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BellEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "bell");
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BellEvent that)) return false;
        return Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(surface); }

    @Override
    public String toString() { return "BellEvent" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public BellEvent build() { return new BellEvent(this); }
    }
}

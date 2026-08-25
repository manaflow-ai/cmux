// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable detached event. Protocol v5; streams: attach-byte, attach-render, attach-browser. */
public final class DetachedEvent implements WireValue, BrowserAttachEvent, ByteAttachEvent, ProtocolEvent, RenderAttachEvent {
    private final UInt64 surface;

    private DetachedEvent(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    @Override public String event() { return "detached"; }

    public static DetachedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DetachedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "detached", "DetachedEvent.event");
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "DetachedEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "detached");
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DetachedEvent that)) return false;
        return Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(surface); }

    @Override
    public String toString() { return "DetachedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public DetachedEvent build() { return new DetachedEvent(this); }
    }
}

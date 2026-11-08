// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable scroll-changed event. Protocol v6; streams: subscribe, attach-byte, attach-render, attach-browser. */
public final class ScrollChangedEvent implements WireValue, BrowserAttachEvent, ByteAttachEvent, DeltaStreamEvent, ProtocolEvent, RenderAttachEvent, SubscribeEvent {
    private final boolean atBottom;
    private final UInt64 offset;
    private final UInt64 surface;

    private ScrollChangedEvent(Builder builder) {
        if (!builder.atBottomSet) throw new IllegalArgumentException("at_bottom is required");
        this.atBottom = builder.atBottom;
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public boolean atBottom() { return atBottom; }
    public UInt64 offset() { return offset; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "scroll-changed"; }

    public static ScrollChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScrollChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "scroll-changed", "ScrollChangedEvent.event");
        Object rawAtBottom = Wire.required(object, "at_bottom");
        builder.atBottom(Wire.bool(rawAtBottom, "ScrollChangedEvent.at_bottom"));
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "ScrollChangedEvent.offset"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ScrollChangedEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "scroll-changed");
        Wire.put(object, "at_bottom", atBottom);
        Wire.put(object, "offset", offset);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScrollChangedEvent that)) return false;
        return Objects.equals(atBottom, that.atBottom) && Objects.equals(offset, that.offset) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(atBottom, offset, surface); }

    @Override
    public String toString() { return "ScrollChangedEvent" + toWire(); }

    public static final class Builder {
        private Boolean atBottom;
        private boolean atBottomSet;
        private UInt64 offset;
        private boolean offsetSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder atBottom(boolean value) {
            this.atBottom = value;
            this.atBottomSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ScrollChangedEvent build() { return new ScrollChangedEvent(this); }
    }
}

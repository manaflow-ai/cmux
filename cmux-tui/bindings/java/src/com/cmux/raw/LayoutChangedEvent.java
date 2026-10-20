// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable layout-changed event. Protocol v6; streams: subscribe. */
public final class LayoutChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 screen;

    private LayoutChangedEvent(Builder builder) {
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 screen() { return screen; }
    @Override public String event() { return "layout-changed"; }

    public static LayoutChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "layout-changed", "LayoutChangedEvent.event");
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "LayoutChangedEvent.screen"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "layout-changed");
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutChangedEvent that)) return false;
        return Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(screen); }

    @Override
    public String toString() { return "LayoutChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 screen;
        private boolean screenSet;

        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public LayoutChangedEvent build() { return new LayoutChangedEvent(this); }
    }
}

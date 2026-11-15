// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable screen-device-changed event. Protocol v12; streams: subscribe. */
public final class ScreenDeviceChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** The authenticated worker screen UUID, or null when the worker is unavailable. */
    private final String screenDeviceId;

    private ScreenDeviceChangedEvent(Builder builder) {
        if (!builder.screenDeviceIdSet) throw new IllegalArgumentException("screen_device_id is required");
        this.screenDeviceId = builder.screenDeviceId;
    }

    public static Builder builder() { return new Builder(); }

    public String screenDeviceId() { return screenDeviceId; }
    @Override public String event() { return "screen-device-changed"; }

    public static ScreenDeviceChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScreenDeviceChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "screen-device-changed", "ScreenDeviceChangedEvent.event");
        Object rawScreenDeviceId = Wire.required(object, "screen_device_id");
        builder.screenDeviceId(rawScreenDeviceId == null ? null : Wire.string(rawScreenDeviceId, "ScreenDeviceChangedEvent.screen_device_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "screen-device-changed");
        Wire.put(object, "screen_device_id", screenDeviceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScreenDeviceChangedEvent that)) return false;
        return Objects.equals(screenDeviceId, that.screenDeviceId);
    }

    @Override
    public int hashCode() { return Objects.hash(screenDeviceId); }

    @Override
    public String toString() { return "ScreenDeviceChangedEvent" + toWire(); }

    public static final class Builder {
        private String screenDeviceId;
        private boolean screenDeviceIdSet;

        public Builder screenDeviceId(String value) {
            this.screenDeviceId = value;
            this.screenDeviceIdSet = true;
            return this;
        }
        public ScreenDeviceChangedEvent build() { return new ScreenDeviceChangedEvent(this); }
    }
}

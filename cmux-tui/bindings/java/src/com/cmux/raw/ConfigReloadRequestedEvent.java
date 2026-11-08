// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable config-reload-requested event. Protocol v6; streams: subscribe. */
public final class ConfigReloadRequestedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {

    private ConfigReloadRequestedEvent(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    @Override public String event() { return "config-reload-requested"; }

    public static ConfigReloadRequestedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConfigReloadRequestedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "config-reload-requested", "ConfigReloadRequestedEvent.event");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "config-reload-requested");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConfigReloadRequestedEvent that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "ConfigReloadRequestedEvent" + toWire(); }

    public static final class Builder {

        public ConfigReloadRequestedEvent build() { return new ConfigReloadRequestedEvent(this); }
    }
}

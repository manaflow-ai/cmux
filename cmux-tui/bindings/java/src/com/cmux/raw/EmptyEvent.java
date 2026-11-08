// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable empty event. Protocol v5; streams: subscribe. */
public final class EmptyEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {

    private EmptyEvent(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    @Override public String event() { return "empty"; }

    public static EmptyEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "EmptyEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "empty", "EmptyEvent.event");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "empty");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof EmptyEvent that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "EmptyEvent" + toWire(); }

    public static final class Builder {

        public EmptyEvent build() { return new EmptyEvent(this); }
    }
}

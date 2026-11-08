// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-list-invalidated event. Protocol v9; streams: subscribe. */
public final class ClientListInvalidatedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {

    private ClientListInvalidatedEvent(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    @Override public String event() { return "client-list-invalidated"; }

    public static ClientListInvalidatedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientListInvalidatedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "client-list-invalidated", "ClientListInvalidatedEvent.event");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "client-list-invalidated");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientListInvalidatedEvent that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "ClientListInvalidatedEvent" + toWire(); }

    public static final class Builder {

        public ClientListInvalidatedEvent build() { return new ClientListInvalidatedEvent(this); }
    }
}

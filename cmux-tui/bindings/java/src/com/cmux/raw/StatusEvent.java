// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable status event. Protocol v5; streams: subscribe. */
public final class StatusEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String message;

    private StatusEvent(Builder builder) {
        if (!builder.messageSet) throw new IllegalArgumentException("message is required");
        this.message = Wire.nonNull(builder.message, "message");
    }

    public static Builder builder() { return new Builder(); }

    public String message() { return message; }
    @Override public String event() { return "status"; }

    public static StatusEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "StatusEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "status", "StatusEvent.event");
        Object rawMessage = Wire.required(object, "message");
        builder.message(Wire.string(rawMessage, "StatusEvent.message"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "status");
        Wire.put(object, "message", message);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof StatusEvent that)) return false;
        return Objects.equals(message, that.message);
    }

    @Override
    public int hashCode() { return Objects.hash(message); }

    @Override
    public String toString() { return "StatusEvent" + toWire(); }

    public static final class Builder {
        private String message;
        private boolean messageSet;

        public Builder message(String value) {
            this.message = value;
            this.messageSet = true;
            return this;
        }
        public StatusEvent build() { return new StatusEvent(this); }
    }
}

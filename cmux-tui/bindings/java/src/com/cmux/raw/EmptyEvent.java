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
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;

    private EmptyEvent(Builder builder) {
        this.cause = builder.cause;
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    @Override public String event() { return "empty"; }

    public static EmptyEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "EmptyEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "empty", "EmptyEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "empty");
        Wire.put(object, "cause", cause);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof EmptyEvent that)) return false;
        return Objects.equals(cause, that.cause);
    }

    @Override
    public int hashCode() { return Objects.hash(cause); }

    @Override
    public String toString() { return "EmptyEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public EmptyEvent build() { return new EmptyEvent(this); }
    }
}

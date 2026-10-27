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
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String message;

    private StatusEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.messageSet) throw new IllegalArgumentException("message is required");
        this.message = Wire.nonNull(builder.message, "message");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public String message() { return message; }
    @Override public String event() { return "status"; }

    public static StatusEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "StatusEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "status", "StatusEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawMessage = Wire.required(object, "message");
        builder.message(Wire.string(rawMessage, "StatusEvent.message"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "status");
        Wire.put(object, "cause", cause);
        Wire.put(object, "message", message);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof StatusEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(message, that.message);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, message); }

    @Override
    public String toString() { return "StatusEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private String message;
        private boolean messageSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder message(String value) {
            this.message = value;
            this.messageSet = true;
            return this;
        }
        public StatusEvent build() { return new StatusEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable pairing-resolved event. Protocol v7; streams: subscribe. */
public final class PairingResolvedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final UInt64 request;

    private PairingResolvedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.requestSet) throw new IllegalArgumentException("request is required");
        this.request = Wire.nonNull(builder.request, "request");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public UInt64 request() { return request; }
    @Override public String event() { return "pairing-resolved"; }

    public static PairingResolvedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PairingResolvedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "pairing-resolved", "PairingResolvedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawRequest = Wire.required(object, "request");
        builder.request(Wire.uint64(rawRequest, "PairingResolvedEvent.request"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "pairing-resolved");
        Wire.put(object, "cause", cause);
        Wire.put(object, "request", request);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PairingResolvedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(request, that.request);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, request); }

    @Override
    public String toString() { return "PairingResolvedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private UInt64 request;
        private boolean requestSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder request(UInt64 value) {
            this.request = value;
            this.requestSet = true;
            return this;
        }
        public PairingResolvedEvent build() { return new PairingResolvedEvent(this); }
    }
}

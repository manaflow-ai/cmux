// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-detached event. Protocol v6; streams: subscribe. */
public final class ClientDetachedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final UInt64 client;

    private ClientDetachedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public UInt64 client() { return client; }
    @Override public String event() { return "client-detached"; }

    public static ClientDetachedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientDetachedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "client-detached", "ClientDetachedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "ClientDetachedEvent.client"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "client-detached");
        Wire.put(object, "cause", cause);
        Wire.put(object, "client", client);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientDetachedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(client, that.client);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, client); }

    @Override
    public String toString() { return "ClientDetachedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private UInt64 client;
        private boolean clientSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public ClientDetachedEvent build() { return new ClientDetachedEvent(this); }
    }
}

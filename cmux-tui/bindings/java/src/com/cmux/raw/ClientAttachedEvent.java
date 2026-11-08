// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-attached event. Protocol v6; streams: subscribe. */
public final class ClientAttachedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 client;
    private final String kind;
    private final String name;
    private final ClientAttachedEventTransport transport;

    private ClientAttachedEvent(Builder builder) {
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = builder.kind;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.transportSet) throw new IllegalArgumentException("transport is required");
        this.transport = Wire.nonNull(builder.transport, "transport");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 client() { return client; }
    public String kind() { return kind; }
    public String name() { return name; }
    public ClientAttachedEventTransport transport() { return transport; }
    @Override public String event() { return "client-attached"; }

    public static ClientAttachedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttachedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "client-attached", "ClientAttachedEvent.event");
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "ClientAttachedEvent.client"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(rawKind == null ? null : Wire.string(rawKind, "ClientAttachedEvent.kind"));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "ClientAttachedEvent.name"));
        Object rawTransport = Wire.required(object, "transport");
        builder.transport(ClientAttachedEventTransport.fromWire(rawTransport));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "client-attached");
        Wire.put(object, "client", client);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "transport", transport);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttachedEvent that)) return false;
        return Objects.equals(client, that.client) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(transport, that.transport);
    }

    @Override
    public int hashCode() { return Objects.hash(client, kind, name, transport); }

    @Override
    public String toString() { return "ClientAttachedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 client;
        private boolean clientSet;
        private String kind;
        private boolean kindSet;
        private String name;
        private boolean nameSet;
        private ClientAttachedEventTransport transport;
        private boolean transportSet;

        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder transport(ClientAttachedEventTransport value) {
            this.transport = value;
            this.transportSet = true;
            return this;
        }
        public ClientAttachedEvent build() { return new ClientAttachedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientInfo implements WireValue {
    private final List<UInt64> attached;
    private final UInt64 client;
    private final UInt64 connectedSeconds;
    private final String kind;
    private final String name;
    private final boolean self;
    private final List<ClientSize> sizes;
    private final ClientTransport transport;

    private ClientInfo(Builder builder) {
        if (!builder.attachedSet) throw new IllegalArgumentException("attached is required");
        this.attached = List.copyOf(Wire.nonNull(builder.attached, "attached"));
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        if (!builder.connectedSecondsSet) throw new IllegalArgumentException("connected_seconds is required");
        this.connectedSeconds = Wire.nonNull(builder.connectedSeconds, "connected_seconds");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = builder.kind;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.selfSet) throw new IllegalArgumentException("self is required");
        this.self = builder.self;
        if (!builder.sizesSet) throw new IllegalArgumentException("sizes is required");
        this.sizes = List.copyOf(Wire.nonNull(builder.sizes, "sizes"));
        if (!builder.transportSet) throw new IllegalArgumentException("transport is required");
        this.transport = Wire.nonNull(builder.transport, "transport");
    }

    public static Builder builder() { return new Builder(); }

    public List<UInt64> attached() { return attached; }
    public UInt64 client() { return client; }
    public UInt64 connectedSeconds() { return connectedSeconds; }
    public String kind() { return kind; }
    public String name() { return name; }
    public boolean self() { return self; }
    public List<ClientSize> sizes() { return sizes; }
    public ClientTransport transport() { return transport; }

    public static ClientInfo fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientInfo");
        Builder builder = builder();
        Object rawAttached = Wire.required(object, "attached");
        builder.attached(Wire.array(rawAttached, "ClientInfo.attached", item -> Wire.uint64(item, "ClientInfo.attached item")));
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "ClientInfo.client"));
        Object rawConnectedSeconds = Wire.required(object, "connected_seconds");
        builder.connectedSeconds(Wire.uint64(rawConnectedSeconds, "ClientInfo.connected_seconds"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(rawKind == null ? null : Wire.string(rawKind, "ClientInfo.kind"));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "ClientInfo.name"));
        Object rawSelf = Wire.required(object, "self");
        builder.self(Wire.bool(rawSelf, "ClientInfo.self"));
        Object rawSizes = Wire.required(object, "sizes");
        builder.sizes(Wire.array(rawSizes, "ClientInfo.sizes", item -> ClientSize.fromWire(item)));
        Object rawTransport = Wire.required(object, "transport");
        builder.transport(ClientTransport.fromWire(rawTransport));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "attached", attached);
        Wire.put(object, "client", client);
        Wire.put(object, "connected_seconds", connectedSeconds);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "self", self);
        Wire.put(object, "sizes", sizes);
        Wire.put(object, "transport", transport);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientInfo that)) return false;
        return Objects.equals(attached, that.attached) && Objects.equals(client, that.client) && Objects.equals(connectedSeconds, that.connectedSeconds) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(self, that.self) && Objects.equals(sizes, that.sizes) && Objects.equals(transport, that.transport);
    }

    @Override
    public int hashCode() { return Objects.hash(attached, client, connectedSeconds, kind, name, self, sizes, transport); }

    @Override
    public String toString() { return "ClientInfo" + toWire(); }

    public static final class Builder {
        private List<UInt64> attached;
        private boolean attachedSet;
        private UInt64 client;
        private boolean clientSet;
        private UInt64 connectedSeconds;
        private boolean connectedSecondsSet;
        private String kind;
        private boolean kindSet;
        private String name;
        private boolean nameSet;
        private Boolean self;
        private boolean selfSet;
        private List<ClientSize> sizes;
        private boolean sizesSet;
        private ClientTransport transport;
        private boolean transportSet;

        public Builder attached(List<UInt64> value) {
            this.attached = value;
            this.attachedSet = true;
            return this;
        }
        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public Builder connectedSeconds(UInt64 value) {
            this.connectedSeconds = value;
            this.connectedSecondsSet = true;
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
        public Builder self(boolean value) {
            this.self = value;
            this.selfSet = true;
            return this;
        }
        public Builder sizes(List<ClientSize> value) {
            this.sizes = value;
            this.sizesSet = true;
            return this;
        }
        public Builder transport(ClientTransport value) {
            this.transport = value;
            this.transportSet = true;
            return this;
        }
        public ClientInfo build() { return new ClientInfo(this); }
    }
}

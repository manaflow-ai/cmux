// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable detach-client request. Protocol v6; authority: control. */
public final class DetachClientRequest implements WireValue {
    private final UInt64 client;

    private DetachClientRequest(Builder builder) {
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 client() { return client; }

    public static DetachClientRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DetachClientRequest");
        Builder builder = builder();
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "DetachClientRequest.client"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client", client);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DetachClientRequest that)) return false;
        return Objects.equals(client, that.client);
    }

    @Override
    public int hashCode() { return Objects.hash(client); }

    @Override
    public String toString() { return "DetachClientRequest" + toWire(); }

    public static final class Builder {
        private UInt64 client;
        private boolean clientSet;

        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public DetachClientRequest build() { return new DetachClientRequest(this); }
    }
}

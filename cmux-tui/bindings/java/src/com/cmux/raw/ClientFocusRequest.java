// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-focus request. Protocol v12; authority: control. */
public final class ClientFocusRequest implements WireValue {
    private final String clientId;

    private ClientFocusRequest(Builder builder) {
        if (!builder.clientIdSet) throw new IllegalArgumentException("client_id is required");
        this.clientId = Wire.nonNull(builder.clientId, "client_id");
    }

    public static Builder builder() { return new Builder(); }

    public String clientId() { return clientId; }

    public static ClientFocusRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientFocusRequest");
        Builder builder = builder();
        Object rawClientId = Wire.required(object, "client_id");
        builder.clientId(Wire.string(rawClientId, "ClientFocusRequest.client_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client_id", clientId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientFocusRequest that)) return false;
        return Objects.equals(clientId, that.clientId);
    }

    @Override
    public int hashCode() { return Objects.hash(clientId); }

    @Override
    public String toString() { return "ClientFocusRequest" + toWire(); }

    public static final class Builder {
        private String clientId;
        private boolean clientIdSet;

        public Builder clientId(String value) {
            this.clientId = value;
            this.clientIdSet = true;
            return this;
        }
        public ClientFocusRequest build() { return new ClientFocusRequest(this); }
    }
}

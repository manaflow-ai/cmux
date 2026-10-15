// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-attention request. Protocol v12; authority: control. */
public final class ClientAttentionRequest implements WireValue {
    /** Only the records of this client id. */
    private final Field<String> clientId;
    /** Also answer pane_attention for this pane. */
    private final Field<UInt64> pane;

    private ClientAttentionRequest(Builder builder) {
        this.clientId = builder.clientId;
        this.pane = builder.pane;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> clientId() { return clientId; }
    public Field<UInt64> pane() { return pane; }

    public static ClientAttentionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttentionRequest");
        Builder builder = builder();
        Object rawClientId = Wire.optional(object, "client_id");
        if (!Wire.isMissing(rawClientId)) {
            builder.clientId(rawClientId == null ? null : Wire.string(rawClientId, "ClientAttentionRequest.client_id"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ClientAttentionRequest.pane"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client_id", clientId);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionRequest that)) return false;
        return Objects.equals(clientId, that.clientId) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(clientId, pane); }

    @Override
    public String toString() { return "ClientAttentionRequest" + toWire(); }

    public static final class Builder {
        private Field<String> clientId = Field.omitted();
        private Field<UInt64> pane = Field.omitted();

        public Builder clientId(String value) {
            this.clientId = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public ClientAttentionRequest build() { return new ClientAttentionRequest(this); }
    }
}

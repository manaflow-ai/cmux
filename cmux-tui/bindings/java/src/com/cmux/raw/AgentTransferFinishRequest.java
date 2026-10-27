// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-finish request. Protocol v12; authority: local-admin. */
public final class AgentTransferFinishRequest implements WireValue {
    private final Field<String> name;
    private final String receiveId;

    private AgentTransferFinishRequest(Builder builder) {
        this.name = builder.name;
        if (!builder.receiveIdSet) throw new IllegalArgumentException("receive_id is required");
        this.receiveId = Wire.nonNull(builder.receiveId, "receive_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> name() { return name; }
    public String receiveId() { return receiveId; }

    public static AgentTransferFinishRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferFinishRequest");
        Builder builder = builder();
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "AgentTransferFinishRequest.name"));
        }
        Object rawReceiveId = Wire.required(object, "receive_id");
        builder.receiveId(Wire.string(rawReceiveId, "AgentTransferFinishRequest.receive_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "name", name);
        Wire.put(object, "receive_id", receiveId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferFinishRequest that)) return false;
        return Objects.equals(name, that.name) && Objects.equals(receiveId, that.receiveId);
    }

    @Override
    public int hashCode() { return Objects.hash(name, receiveId); }

    @Override
    public String toString() { return "AgentTransferFinishRequest" + toWire(); }

    public static final class Builder {
        private Field<String> name = Field.omitted();
        private String receiveId;
        private boolean receiveIdSet;

        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder receiveId(String value) {
            this.receiveId = value;
            this.receiveIdSet = true;
            return this;
        }
        public AgentTransferFinishRequest build() { return new AgentTransferFinishRequest(this); }
    }
}

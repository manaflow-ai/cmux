// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-receive-abort request. Protocol v12; authority: local-admin. */
public final class AgentTransferReceiveAbortRequest implements WireValue {
    private final String receiveId;

    private AgentTransferReceiveAbortRequest(Builder builder) {
        if (!builder.receiveIdSet) throw new IllegalArgumentException("receive_id is required");
        this.receiveId = Wire.nonNull(builder.receiveId, "receive_id");
    }

    public static Builder builder() { return new Builder(); }

    public String receiveId() { return receiveId; }

    public static AgentTransferReceiveAbortRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferReceiveAbortRequest");
        Builder builder = builder();
        Object rawReceiveId = Wire.required(object, "receive_id");
        builder.receiveId(Wire.string(rawReceiveId, "AgentTransferReceiveAbortRequest.receive_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "receive_id", receiveId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferReceiveAbortRequest that)) return false;
        return Objects.equals(receiveId, that.receiveId);
    }

    @Override
    public int hashCode() { return Objects.hash(receiveId); }

    @Override
    public String toString() { return "AgentTransferReceiveAbortRequest" + toWire(); }

    public static final class Builder {
        private String receiveId;
        private boolean receiveIdSet;

        public Builder receiveId(String value) {
            this.receiveId = value;
            this.receiveIdSet = true;
            return this;
        }
        public AgentTransferReceiveAbortRequest build() { return new AgentTransferReceiveAbortRequest(this); }
    }
}

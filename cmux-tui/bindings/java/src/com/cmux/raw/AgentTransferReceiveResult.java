// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferReceiveResult implements WireValue {
    private final String receiveId;
    private final String sessionId;

    private AgentTransferReceiveResult(Builder builder) {
        if (!builder.receiveIdSet) throw new IllegalArgumentException("receive_id is required");
        this.receiveId = Wire.nonNull(builder.receiveId, "receive_id");
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
    }

    public static Builder builder() { return new Builder(); }

    public String receiveId() { return receiveId; }
    public String sessionId() { return sessionId; }

    public static AgentTransferReceiveResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferReceiveResult");
        Builder builder = builder();
        Object rawReceiveId = Wire.required(object, "receive_id");
        builder.receiveId(Wire.string(rawReceiveId, "AgentTransferReceiveResult.receive_id"));
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "AgentTransferReceiveResult.session_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "receive_id", receiveId);
        Wire.put(object, "session_id", sessionId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferReceiveResult that)) return false;
        return Objects.equals(receiveId, that.receiveId) && Objects.equals(sessionId, that.sessionId);
    }

    @Override
    public int hashCode() { return Objects.hash(receiveId, sessionId); }

    @Override
    public String toString() { return "AgentTransferReceiveResult" + toWire(); }

    public static final class Builder {
        private String receiveId;
        private boolean receiveIdSet;
        private String sessionId;
        private boolean sessionIdSet;

        public Builder receiveId(String value) {
            this.receiveId = value;
            this.receiveIdSet = true;
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public AgentTransferReceiveResult build() { return new AgentTransferReceiveResult(this); }
    }
}

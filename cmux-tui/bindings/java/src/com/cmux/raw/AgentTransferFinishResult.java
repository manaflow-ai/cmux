// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferFinishResult implements WireValue {
    private final Object session;

    private AgentTransferFinishResult(Builder builder) {
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.immutableJson(Wire.nonNull(builder.session, "session"));
    }

    public static Builder builder() { return new Builder(); }

    public Object session() { return session; }

    public static AgentTransferFinishResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferFinishResult");
        Builder builder = builder();
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.immutableJson(rawSession));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferFinishResult that)) return false;
        return Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(session); }

    @Override
    public String toString() { return "AgentTransferFinishResult" + toWire(); }

    public static final class Builder {
        private Object session;
        private boolean sessionSet;

        public Builder session(Object value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public AgentTransferFinishResult build() { return new AgentTransferFinishResult(this); }
    }
}

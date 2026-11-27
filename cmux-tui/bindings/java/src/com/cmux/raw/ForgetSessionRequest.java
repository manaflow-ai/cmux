// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable forget-session request. Protocol v12; authority: control. */
public final class ForgetSessionRequest implements WireValue {
    private final Field<Boolean> force;
    private final String sessionId;

    private ForgetSessionRequest(Builder builder) {
        this.force = builder.force;
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> force() { return force; }
    public String sessionId() { return sessionId; }

    public static ForgetSessionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ForgetSessionRequest");
        Builder builder = builder();
        Object rawForce = Wire.optional(object, "force");
        if (!Wire.isMissing(rawForce)) {
            builder.force(Wire.bool(rawForce, "ForgetSessionRequest.force"));
        }
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "ForgetSessionRequest.session_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "force", force);
        Wire.put(object, "session_id", sessionId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ForgetSessionRequest that)) return false;
        return Objects.equals(force, that.force) && Objects.equals(sessionId, that.sessionId);
    }

    @Override
    public int hashCode() { return Objects.hash(force, sessionId); }

    @Override
    public String toString() { return "ForgetSessionRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> force = Field.omitted();
        private String sessionId;
        private boolean sessionIdSet;

        public Builder force(Boolean value) {
            this.force = Field.of(value);
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public ForgetSessionRequest build() { return new ForgetSessionRequest(this); }
    }
}

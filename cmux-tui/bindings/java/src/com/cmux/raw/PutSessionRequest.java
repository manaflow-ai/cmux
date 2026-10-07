// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable put-session request. Protocol v12; authority: control. */
public final class PutSessionRequest implements WireValue {
    private final Field<Object> capabilities;
    private final Field<String> followWith;
    private final Field<String> machineName;
    private final String sessionId;
    private final Field<String> sessionName;
    private final Object transport;

    private PutSessionRequest(Builder builder) {
        this.capabilities = builder.capabilities.map(value -> Wire.immutableJson(value));
        this.followWith = builder.followWith;
        this.machineName = builder.machineName;
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        this.sessionName = builder.sessionName;
        if (!builder.transportSet) throw new IllegalArgumentException("transport is required");
        this.transport = builder.transport == null ? null : Wire.immutableJson(builder.transport);
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> capabilities() { return capabilities; }
    public Field<String> followWith() { return followWith; }
    public Field<String> machineName() { return machineName; }
    public String sessionId() { return sessionId; }
    public Field<String> sessionName() { return sessionName; }
    public Object transport() { return transport; }

    public static PutSessionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PutSessionRequest");
        Builder builder = builder();
        Object rawCapabilities = Wire.optional(object, "capabilities");
        if (!Wire.isMissing(rawCapabilities)) {
            builder.capabilities(rawCapabilities == null ? null : Wire.immutableJson(rawCapabilities));
        }
        Object rawFollowWith = Wire.optional(object, "follow_with");
        if (!Wire.isMissing(rawFollowWith)) {
            builder.followWith(rawFollowWith == null ? null : Wire.string(rawFollowWith, "PutSessionRequest.follow_with"));
        }
        Object rawMachineName = Wire.optional(object, "machine_name");
        if (!Wire.isMissing(rawMachineName)) {
            builder.machineName(rawMachineName == null ? null : Wire.string(rawMachineName, "PutSessionRequest.machine_name"));
        }
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "PutSessionRequest.session_id"));
        Object rawSessionName = Wire.optional(object, "session_name");
        if (!Wire.isMissing(rawSessionName)) {
            builder.sessionName(rawSessionName == null ? null : Wire.string(rawSessionName, "PutSessionRequest.session_name"));
        }
        Object rawTransport = Wire.required(object, "transport");
        builder.transport(rawTransport == null ? null : Wire.immutableJson(rawTransport));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "capabilities", capabilities);
        Wire.put(object, "follow_with", followWith);
        Wire.put(object, "machine_name", machineName);
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "session_name", sessionName);
        Wire.put(object, "transport", transport);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PutSessionRequest that)) return false;
        return Objects.equals(capabilities, that.capabilities) && Objects.equals(followWith, that.followWith) && Objects.equals(machineName, that.machineName) && Objects.equals(sessionId, that.sessionId) && Objects.equals(sessionName, that.sessionName) && Objects.equals(transport, that.transport);
    }

    @Override
    public int hashCode() { return Objects.hash(capabilities, followWith, machineName, sessionId, sessionName, transport); }

    @Override
    public String toString() { return "PutSessionRequest" + toWire(); }

    public static final class Builder {
        private Field<Object> capabilities = Field.omitted();
        private Field<String> followWith = Field.omitted();
        private Field<String> machineName = Field.omitted();
        private String sessionId;
        private boolean sessionIdSet;
        private Field<String> sessionName = Field.omitted();
        private Object transport;
        private boolean transportSet;

        public Builder capabilities(Object value) {
            this.capabilities = Field.ofNullable(value);
            return this;
        }
        public Builder followWith(String value) {
            this.followWith = Field.ofNullable(value);
            return this;
        }
        public Builder machineName(String value) {
            this.machineName = Field.ofNullable(value);
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder sessionName(String value) {
            this.sessionName = Field.ofNullable(value);
            return this;
        }
        public Builder transport(Object value) {
            this.transport = value;
            this.transportSet = true;
            return this;
        }
        public PutSessionRequest build() { return new PutSessionRequest(this); }
    }
}

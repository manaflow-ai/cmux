// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-permission request. Protocol v12; authority: local-admin. */
public final class AgentSessionPermissionRequest implements WireValue {
    private final Field<AgentSessionAnsweredBy> answeredBy;
    /** 64 lowercase hex characters. */
    private final Field<String> decisionNonce;
    /** The chosen option, 1 to 256 bytes. */
    private final String optionId;
    /** A request acpmux announced on this attachment. */
    private final String permissionId;
    /** 64 lowercase hex characters: the person's decision proof. */
    private final Field<String> personDecision;
    /** The agent chat tab: an agent_session tab of this daemon's store. */
    private final UInt64 surface;

    private AgentSessionPermissionRequest(Builder builder) {
        this.answeredBy = builder.answeredBy;
        this.decisionNonce = builder.decisionNonce;
        if (!builder.optionIdSet) throw new IllegalArgumentException("option_id is required");
        this.optionId = Wire.nonNull(builder.optionId, "option_id");
        if (!builder.permissionIdSet) throw new IllegalArgumentException("permission_id is required");
        this.permissionId = Wire.nonNull(builder.permissionId, "permission_id");
        this.personDecision = builder.personDecision;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<AgentSessionAnsweredBy> answeredBy() { return answeredBy; }
    public Field<String> decisionNonce() { return decisionNonce; }
    public String optionId() { return optionId; }
    public String permissionId() { return permissionId; }
    public Field<String> personDecision() { return personDecision; }
    public UInt64 surface() { return surface; }

    public static AgentSessionPermissionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionPermissionRequest");
        Builder builder = builder();
        Object rawAnsweredBy = Wire.optional(object, "answered_by");
        if (!Wire.isMissing(rawAnsweredBy)) {
            builder.answeredBy(rawAnsweredBy == null ? null : AgentSessionAnsweredBy.fromWire(rawAnsweredBy));
        }
        Object rawDecisionNonce = Wire.optional(object, "decision_nonce");
        if (!Wire.isMissing(rawDecisionNonce)) {
            builder.decisionNonce(rawDecisionNonce == null ? null : Wire.string(rawDecisionNonce, "AgentSessionPermissionRequest.decision_nonce"));
        }
        Object rawOptionId = Wire.required(object, "option_id");
        builder.optionId(Wire.string(rawOptionId, "AgentSessionPermissionRequest.option_id"));
        Object rawPermissionId = Wire.required(object, "permission_id");
        builder.permissionId(Wire.string(rawPermissionId, "AgentSessionPermissionRequest.permission_id"));
        Object rawPersonDecision = Wire.optional(object, "person_decision");
        if (!Wire.isMissing(rawPersonDecision)) {
            builder.personDecision(rawPersonDecision == null ? null : Wire.string(rawPersonDecision, "AgentSessionPermissionRequest.person_decision"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionPermissionRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "answered_by", answeredBy);
        Wire.put(object, "decision_nonce", decisionNonce);
        Wire.put(object, "option_id", optionId);
        Wire.put(object, "permission_id", permissionId);
        Wire.put(object, "person_decision", personDecision);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionPermissionRequest that)) return false;
        return Objects.equals(answeredBy, that.answeredBy) && Objects.equals(decisionNonce, that.decisionNonce) && Objects.equals(optionId, that.optionId) && Objects.equals(permissionId, that.permissionId) && Objects.equals(personDecision, that.personDecision) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(answeredBy, decisionNonce, optionId, permissionId, personDecision, surface); }

    @Override
    public String toString() { return "AgentSessionPermissionRequest" + toWire(); }

    public static final class Builder {
        private Field<AgentSessionAnsweredBy> answeredBy = Field.omitted();
        private Field<String> decisionNonce = Field.omitted();
        private String optionId;
        private boolean optionIdSet;
        private String permissionId;
        private boolean permissionIdSet;
        private Field<String> personDecision = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder answeredBy(AgentSessionAnsweredBy value) {
            this.answeredBy = Field.ofNullable(value);
            return this;
        }
        public Builder decisionNonce(String value) {
            this.decisionNonce = Field.ofNullable(value);
            return this;
        }
        public Builder optionId(String value) {
            this.optionId = value;
            this.optionIdSet = true;
            return this;
        }
        public Builder permissionId(String value) {
            this.permissionId = value;
            this.permissionIdSet = true;
            return this;
        }
        public Builder personDecision(String value) {
            this.personDecision = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentSessionPermissionRequest build() { return new AgentSessionPermissionRequest(this); }
    }
}

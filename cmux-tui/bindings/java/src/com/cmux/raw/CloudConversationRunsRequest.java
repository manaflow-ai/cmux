// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-runs request. Protocol v12; authority: local-admin. */
public final class CloudConversationRunsRequest implements WireValue {
    private final String agent;
    private final Field<UInt64> beforeStartedAt;
    private final String conversation;
    private final Field<Long> limit;

    private CloudConversationRunsRequest(Builder builder) {
        if (!builder.agentSet) throw new IllegalArgumentException("agent is required");
        this.agent = Wire.nonNull(builder.agent, "agent");
        this.beforeStartedAt = builder.beforeStartedAt;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.limit = builder.limit;
    }

    public static Builder builder() { return new Builder(); }

    public String agent() { return agent; }
    public Field<UInt64> beforeStartedAt() { return beforeStartedAt; }
    public String conversation() { return conversation; }
    public Field<Long> limit() { return limit; }

    public static CloudConversationRunsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationRunsRequest");
        Builder builder = builder();
        Object rawAgent = Wire.required(object, "agent");
        builder.agent(Wire.string(rawAgent, "CloudConversationRunsRequest.agent"));
        Object rawBeforeStartedAt = Wire.optional(object, "before_started_at");
        if (!Wire.isMissing(rawBeforeStartedAt)) {
            builder.beforeStartedAt(rawBeforeStartedAt == null ? null : Wire.uint64(rawBeforeStartedAt, "CloudConversationRunsRequest.before_started_at"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationRunsRequest.conversation"));
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "CloudConversationRunsRequest.limit"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agent", agent);
        Wire.put(object, "before_started_at", beforeStartedAt);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "limit", limit);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationRunsRequest that)) return false;
        return Objects.equals(agent, that.agent) && Objects.equals(beforeStartedAt, that.beforeStartedAt) && Objects.equals(conversation, that.conversation) && Objects.equals(limit, that.limit);
    }

    @Override
    public int hashCode() { return Objects.hash(agent, beforeStartedAt, conversation, limit); }

    @Override
    public String toString() { return "CloudConversationRunsRequest" + toWire(); }

    public static final class Builder {
        private String agent;
        private boolean agentSet;
        private Field<UInt64> beforeStartedAt = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Field<Long> limit = Field.omitted();

        public Builder agent(String value) {
            this.agent = value;
            this.agentSet = true;
            return this;
        }
        public Builder beforeStartedAt(UInt64 value) {
            this.beforeStartedAt = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder limit(Long value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public CloudConversationRunsRequest build() { return new CloudConversationRunsRequest(this); }
    }
}

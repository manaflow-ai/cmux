// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-run request. Protocol v12; authority: local-admin. */
public final class CloudConversationRunRequest implements WireValue {
    private final Field<UInt64> afterSeq;
    private final String agent;
    private final String conversation;
    private final String run;

    private CloudConversationRunRequest(Builder builder) {
        this.afterSeq = builder.afterSeq;
        if (!builder.agentSet) throw new IllegalArgumentException("agent is required");
        this.agent = Wire.nonNull(builder.agent, "agent");
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = Wire.nonNull(builder.run, "run");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterSeq() { return afterSeq; }
    public String agent() { return agent; }
    public String conversation() { return conversation; }
    public String run() { return run; }

    public static CloudConversationRunRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationRunRequest");
        Builder builder = builder();
        Object rawAfterSeq = Wire.optional(object, "after_seq");
        if (!Wire.isMissing(rawAfterSeq)) {
            builder.afterSeq(rawAfterSeq == null ? null : Wire.uint64(rawAfterSeq, "CloudConversationRunRequest.after_seq"));
        }
        Object rawAgent = Wire.required(object, "agent");
        builder.agent(Wire.string(rawAgent, "CloudConversationRunRequest.agent"));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationRunRequest.conversation"));
        Object rawRun = Wire.required(object, "run");
        builder.run(Wire.string(rawRun, "CloudConversationRunRequest.run"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_seq", afterSeq);
        Wire.put(object, "agent", agent);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "run", run);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationRunRequest that)) return false;
        return Objects.equals(afterSeq, that.afterSeq) && Objects.equals(agent, that.agent) && Objects.equals(conversation, that.conversation) && Objects.equals(run, that.run);
    }

    @Override
    public int hashCode() { return Objects.hash(afterSeq, agent, conversation, run); }

    @Override
    public String toString() { return "CloudConversationRunRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterSeq = Field.omitted();
        private String agent;
        private boolean agentSet;
        private String conversation;
        private boolean conversationSet;
        private String run;
        private boolean runSet;

        public Builder afterSeq(UInt64 value) {
            this.afterSeq = Field.ofNullable(value);
            return this;
        }
        public Builder agent(String value) {
            this.agent = value;
            this.agentSet = true;
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder run(String value) {
            this.run = value;
            this.runSet = true;
            return this;
        }
        public CloudConversationRunRequest build() { return new CloudConversationRunRequest(this); }
    }
}

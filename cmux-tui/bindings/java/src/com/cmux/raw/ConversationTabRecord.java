// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationTabRecord implements WireValue {
    /** Agent session source (agent-session-tabs-v1); exclusive with conversation and owner. */
    private final Field<AgentSessionSource> agentSession;
    /** Conversation source: a conv_ id, with owner. */
    private final Field<String> conversation;
    /** Conversation source: local or cloud. */
    private final Field<String> owner;

    private ConversationTabRecord(Builder builder) {
        this.agentSession = builder.agentSession;
        this.conversation = builder.conversation;
        this.owner = builder.owner;
    }

    public static Builder builder() { return new Builder(); }

    public Field<AgentSessionSource> agentSession() { return agentSession; }
    public Field<String> conversation() { return conversation; }
    public Field<String> owner() { return owner; }

    public static ConversationTabRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTabRecord");
        Builder builder = builder();
        Object rawAgentSession = Wire.optional(object, "agent_session");
        if (!Wire.isMissing(rawAgentSession)) {
            builder.agentSession(AgentSessionSource.fromWire(rawAgentSession));
        }
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(Wire.string(rawConversation, "ConversationTabRecord.conversation"));
        }
        Object rawOwner = Wire.optional(object, "owner");
        if (!Wire.isMissing(rawOwner)) {
            builder.owner(Wire.string(rawOwner, "ConversationTabRecord.owner"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agent_session", agentSession);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "owner", owner);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTabRecord that)) return false;
        return Objects.equals(agentSession, that.agentSession) && Objects.equals(conversation, that.conversation) && Objects.equals(owner, that.owner);
    }

    @Override
    public int hashCode() { return Objects.hash(agentSession, conversation, owner); }

    @Override
    public String toString() { return "ConversationTabRecord" + toWire(); }

    public static final class Builder {
        private Field<AgentSessionSource> agentSession = Field.omitted();
        private Field<String> conversation = Field.omitted();
        private Field<String> owner = Field.omitted();

        public Builder agentSession(AgentSessionSource value) {
            this.agentSession = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = Field.of(value);
            return this;
        }
        public Builder owner(String value) {
            this.owner = Field.of(value);
            return this;
        }
        public ConversationTabRecord build() { return new ConversationTabRecord(this); }
    }
}

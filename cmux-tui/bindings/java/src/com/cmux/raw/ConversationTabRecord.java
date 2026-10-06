// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationTabRecord implements WireValue {
    /** Agent session source (agent-session-tabs-v1); exclusive with the other sources. */
    private final Field<AgentSessionSource> agentSession;
    /** Conversation source: a conv_ id, with owner. */
    private final Field<String> conversation;
    /** Conversation source: local or cloud. */
    private final Field<String> owner;
    /** Page source (page-tabs-v1): the id of one of the app's own pages; exclusive with the other sources. */
    private final Field<String> page;

    private ConversationTabRecord(Builder builder) {
        this.agentSession = builder.agentSession;
        this.conversation = builder.conversation;
        this.owner = builder.owner;
        this.page = builder.page;
    }

    public static Builder builder() { return new Builder(); }

    public Field<AgentSessionSource> agentSession() { return agentSession; }
    public Field<String> conversation() { return conversation; }
    public Field<String> owner() { return owner; }
    public Field<String> page() { return page; }

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
        Object rawPage = Wire.optional(object, "page");
        if (!Wire.isMissing(rawPage)) {
            builder.page(Wire.string(rawPage, "ConversationTabRecord.page"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agent_session", agentSession);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "owner", owner);
        Wire.put(object, "page", page);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTabRecord that)) return false;
        return Objects.equals(agentSession, that.agentSession) && Objects.equals(conversation, that.conversation) && Objects.equals(owner, that.owner) && Objects.equals(page, that.page);
    }

    @Override
    public int hashCode() { return Objects.hash(agentSession, conversation, owner, page); }

    @Override
    public String toString() { return "ConversationTabRecord" + toWire(); }

    public static final class Builder {
        private Field<AgentSessionSource> agentSession = Field.omitted();
        private Field<String> conversation = Field.omitted();
        private Field<String> owner = Field.omitted();
        private Field<String> page = Field.omitted();

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
        public Builder page(String value) {
            this.page = Field.of(value);
            return this;
        }
        public ConversationTabRecord build() { return new ConversationTabRecord(this); }
    }
}

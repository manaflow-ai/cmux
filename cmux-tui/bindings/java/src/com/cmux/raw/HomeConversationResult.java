// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HomeConversationResult implements WireValue {
    private final HomeAgentsPaused agentsPaused;
    private final ConversationSummary conversation;
    private final boolean hasOlder;
    private final List<Object> messages;
    private final List<ConversationThreadSummary> threads;

    private HomeConversationResult(Builder builder) {
        if (!builder.agentsPausedSet) throw new IllegalArgumentException("agents_paused is required");
        this.agentsPaused = Wire.nonNull(builder.agentsPaused, "agents_paused");
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.hasOlderSet) throw new IllegalArgumentException("has_older is required");
        this.hasOlder = builder.hasOlder;
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = List.copyOf(Wire.nonNull(builder.messages, "messages"));
        if (!builder.threadsSet) throw new IllegalArgumentException("threads is required");
        this.threads = List.copyOf(Wire.nonNull(builder.threads, "threads"));
    }

    public static Builder builder() { return new Builder(); }

    public HomeAgentsPaused agentsPaused() { return agentsPaused; }
    public ConversationSummary conversation() { return conversation; }
    public boolean hasOlder() { return hasOlder; }
    public List<Object> messages() { return messages; }
    public List<ConversationThreadSummary> threads() { return threads; }

    public static HomeConversationResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeConversationResult");
        Builder builder = builder();
        Object rawAgentsPaused = Wire.required(object, "agents_paused");
        builder.agentsPaused(HomeAgentsPaused.fromWire(rawAgentsPaused));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationSummary.fromWire(rawConversation));
        Object rawHasOlder = Wire.required(object, "has_older");
        builder.hasOlder(Wire.bool(rawHasOlder, "HomeConversationResult.has_older"));
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.array(rawMessages, "HomeConversationResult.messages", item -> Wire.immutableJson(item)));
        Object rawThreads = Wire.required(object, "threads");
        builder.threads(Wire.array(rawThreads, "HomeConversationResult.threads", item -> ConversationThreadSummary.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agents_paused", agentsPaused);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "has_older", hasOlder);
        Wire.put(object, "messages", messages);
        Wire.put(object, "threads", threads);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeConversationResult that)) return false;
        return Objects.equals(agentsPaused, that.agentsPaused) && Objects.equals(conversation, that.conversation) && Objects.equals(hasOlder, that.hasOlder) && Objects.equals(messages, that.messages) && Objects.equals(threads, that.threads);
    }

    @Override
    public int hashCode() { return Objects.hash(agentsPaused, conversation, hasOlder, messages, threads); }

    @Override
    public String toString() { return "HomeConversationResult" + toWire(); }

    public static final class Builder {
        private HomeAgentsPaused agentsPaused;
        private boolean agentsPausedSet;
        private ConversationSummary conversation;
        private boolean conversationSet;
        private Boolean hasOlder;
        private boolean hasOlderSet;
        private List<Object> messages;
        private boolean messagesSet;
        private List<ConversationThreadSummary> threads;
        private boolean threadsSet;

        public Builder agentsPaused(HomeAgentsPaused value) {
            this.agentsPaused = value;
            this.agentsPausedSet = true;
            return this;
        }
        public Builder conversation(ConversationSummary value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder hasOlder(boolean value) {
            this.hasOlder = value;
            this.hasOlderSet = true;
            return this;
        }
        public Builder messages(List<Object> value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public Builder threads(List<ConversationThreadSummary> value) {
            this.threads = value;
            this.threadsSet = true;
            return this;
        }
        public HomeConversationResult build() { return new HomeConversationResult(this); }
    }
}

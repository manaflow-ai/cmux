// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationSnapshotResult implements WireValue {
    private final ConversationSummary conversation;
    private final List<ConversationMessage> messages;
    private final Field<List<ConversationThreadSummary>> threads;

    private ConversationSnapshotResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = List.copyOf(Wire.nonNull(builder.messages, "messages"));
        this.threads = builder.threads.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public ConversationSummary conversation() { return conversation; }
    public List<ConversationMessage> messages() { return messages; }
    public Field<List<ConversationThreadSummary>> threads() { return threads; }

    public static ConversationSnapshotResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationSnapshotResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationSummary.fromWire(rawConversation));
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.array(rawMessages, "ConversationSnapshotResult.messages", item -> ConversationMessage.fromWire(item)));
        Object rawThreads = Wire.optional(object, "threads");
        if (!Wire.isMissing(rawThreads)) {
            builder.threads(Wire.array(rawThreads, "ConversationSnapshotResult.threads", item -> ConversationThreadSummary.fromWire(item)));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "messages", messages);
        Wire.put(object, "threads", threads);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationSnapshotResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(messages, that.messages) && Objects.equals(threads, that.threads);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, messages, threads); }

    @Override
    public String toString() { return "ConversationSnapshotResult" + toWire(); }

    public static final class Builder {
        private ConversationSummary conversation;
        private boolean conversationSet;
        private List<ConversationMessage> messages;
        private boolean messagesSet;
        private Field<List<ConversationThreadSummary>> threads = Field.omitted();

        public Builder conversation(ConversationSummary value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder messages(List<ConversationMessage> value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public Builder threads(List<ConversationThreadSummary> value) {
            this.threads = Field.of(value);
            return this;
        }
        public ConversationSnapshotResult build() { return new ConversationSnapshotResult(this); }
    }
}

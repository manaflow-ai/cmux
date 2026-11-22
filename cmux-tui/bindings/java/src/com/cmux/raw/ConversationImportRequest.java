// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-import request. Protocol v12; authority: local-admin. */
public final class ConversationImportRequest implements WireValue {
    private final String conversation;
    private final List<ConversationImportMessage> messages;

    private ConversationImportRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = List.copyOf(Wire.nonNull(builder.messages, "messages"));
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public List<ConversationImportMessage> messages() { return messages; }

    public static ConversationImportRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationImportRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationImportRequest.conversation"));
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.array(rawMessages, "ConversationImportRequest.messages", item -> ConversationImportMessage.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "messages", messages);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationImportRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(messages, that.messages);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, messages); }

    @Override
    public String toString() { return "ConversationImportRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private List<ConversationImportMessage> messages;
        private boolean messagesSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder messages(List<ConversationImportMessage> value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public ConversationImportRequest build() { return new ConversationImportRequest(this); }
    }
}

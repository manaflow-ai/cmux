// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationChangeConversation implements WireValue, ConversationChange {
    private final ConversationSummary conversation;

    private ConversationChangeConversation(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
    }

    public static Builder builder() { return new Builder(); }

    public ConversationSummary conversation() { return conversation; }
    public String kind() { return "conversation"; }

    public static ConversationChangeConversation fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationChangeConversation");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationSummary.fromWire(rawConversation));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "conversation", "ConversationChangeConversation.kind");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "kind", "conversation");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationChangeConversation that)) return false;
        return Objects.equals(conversation, that.conversation);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation); }

    @Override
    public String toString() { return "ConversationChangeConversation" + toWire(); }

    public static final class Builder {
        private ConversationSummary conversation;
        private boolean conversationSet;

        public Builder conversation(ConversationSummary value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public ConversationChangeConversation build() { return new ConversationChangeConversation(this); }
    }
}

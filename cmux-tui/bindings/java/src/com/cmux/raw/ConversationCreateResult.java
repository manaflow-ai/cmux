// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationCreateResult implements WireValue {
    private final ConversationSummary conversation;
    private final boolean replayed;

    private ConversationCreateResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
    }

    public static Builder builder() { return new Builder(); }

    public ConversationSummary conversation() { return conversation; }
    public boolean replayed() { return replayed; }

    public static ConversationCreateResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationCreateResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationSummary.fromWire(rawConversation));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "ConversationCreateResult.replayed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "replayed", replayed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationCreateResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(replayed, that.replayed);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, replayed); }

    @Override
    public String toString() { return "ConversationCreateResult" + toWire(); }

    public static final class Builder {
        private ConversationSummary conversation;
        private boolean conversationSet;
        private Boolean replayed;
        private boolean replayedSet;

        public Builder conversation(ConversationSummary value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public ConversationCreateResult build() { return new ConversationCreateResult(this); }
    }
}

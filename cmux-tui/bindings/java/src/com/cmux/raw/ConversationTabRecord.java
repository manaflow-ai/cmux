// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationTabRecord implements WireValue {
    private final String conversation;
    private final String owner;

    private ConversationTabRecord(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.ownerSet) throw new IllegalArgumentException("owner is required");
        this.owner = Wire.nonNull(builder.owner, "owner");
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public String owner() { return owner; }

    public static ConversationTabRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTabRecord");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationTabRecord.conversation"));
        Object rawOwner = Wire.required(object, "owner");
        builder.owner(Wire.string(rawOwner, "ConversationTabRecord.owner"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "owner", owner);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTabRecord that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(owner, that.owner);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, owner); }

    @Override
    public String toString() { return "ConversationTabRecord" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private String owner;
        private boolean ownerSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder owner(String value) {
            this.owner = value;
            this.ownerSet = true;
            return this;
        }
        public ConversationTabRecord build() { return new ConversationTabRecord(this); }
    }
}

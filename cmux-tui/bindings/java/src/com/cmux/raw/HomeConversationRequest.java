// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable home-conversation request. Protocol v12; authority: local-admin. */
public final class HomeConversationRequest implements WireValue {
    private final Field<UInt64> beforeSeq;
    private final String conversation;
    private final Field<Long> limit;
    private final Field<Long> tail;

    private HomeConversationRequest(Builder builder) {
        this.beforeSeq = builder.beforeSeq;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.limit = builder.limit;
        this.tail = builder.tail;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> beforeSeq() { return beforeSeq; }
    public String conversation() { return conversation; }
    public Field<Long> limit() { return limit; }
    public Field<Long> tail() { return tail; }

    public static HomeConversationRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeConversationRequest");
        Builder builder = builder();
        Object rawBeforeSeq = Wire.optional(object, "before_seq");
        if (!Wire.isMissing(rawBeforeSeq)) {
            builder.beforeSeq(rawBeforeSeq == null ? null : Wire.uint64(rawBeforeSeq, "HomeConversationRequest.before_seq"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "HomeConversationRequest.conversation"));
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "HomeConversationRequest.limit"));
        }
        Object rawTail = Wire.optional(object, "tail");
        if (!Wire.isMissing(rawTail)) {
            builder.tail(rawTail == null ? null : Wire.uint32(rawTail, "HomeConversationRequest.tail"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "before_seq", beforeSeq);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "limit", limit);
        Wire.put(object, "tail", tail);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeConversationRequest that)) return false;
        return Objects.equals(beforeSeq, that.beforeSeq) && Objects.equals(conversation, that.conversation) && Objects.equals(limit, that.limit) && Objects.equals(tail, that.tail);
    }

    @Override
    public int hashCode() { return Objects.hash(beforeSeq, conversation, limit, tail); }

    @Override
    public String toString() { return "HomeConversationRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> beforeSeq = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Field<Long> limit = Field.omitted();
        private Field<Long> tail = Field.omitted();

        public Builder beforeSeq(UInt64 value) {
            this.beforeSeq = Field.ofNullable(value);
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
        public Builder tail(Long value) {
            this.tail = Field.ofNullable(value);
            return this;
        }
        public HomeConversationRequest build() { return new HomeConversationRequest(this); }
    }
}

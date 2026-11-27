// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-thread request. Protocol v12; authority: local-admin. */
public final class ConversationThreadRequest implements WireValue {
    private final Field<UInt64> afterSeq;
    private final String conversation;
    private final Field<Long> limit;
    private final String root;

    private ConversationThreadRequest(Builder builder) {
        this.afterSeq = builder.afterSeq;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.limit = builder.limit;
        if (!builder.rootSet) throw new IllegalArgumentException("root is required");
        this.root = Wire.nonNull(builder.root, "root");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterSeq() { return afterSeq; }
    public String conversation() { return conversation; }
    public Field<Long> limit() { return limit; }
    public String root() { return root; }

    public static ConversationThreadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationThreadRequest");
        Builder builder = builder();
        Object rawAfterSeq = Wire.optional(object, "after_seq");
        if (!Wire.isMissing(rawAfterSeq)) {
            builder.afterSeq(Wire.uint64(rawAfterSeq, "ConversationThreadRequest.after_seq"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationThreadRequest.conversation"));
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "ConversationThreadRequest.limit"));
        }
        Object rawRoot = Wire.required(object, "root");
        builder.root(Wire.string(rawRoot, "ConversationThreadRequest.root"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_seq", afterSeq);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "limit", limit);
        Wire.put(object, "root", root);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationThreadRequest that)) return false;
        return Objects.equals(afterSeq, that.afterSeq) && Objects.equals(conversation, that.conversation) && Objects.equals(limit, that.limit) && Objects.equals(root, that.root);
    }

    @Override
    public int hashCode() { return Objects.hash(afterSeq, conversation, limit, root); }

    @Override
    public String toString() { return "ConversationThreadRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterSeq = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Field<Long> limit = Field.omitted();
        private String root;
        private boolean rootSet;

        public Builder afterSeq(UInt64 value) {
            this.afterSeq = Field.of(value);
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
        public Builder root(String value) {
            this.root = value;
            this.rootSet = true;
            return this;
        }
        public ConversationThreadRequest build() { return new ConversationThreadRequest(this); }
    }
}

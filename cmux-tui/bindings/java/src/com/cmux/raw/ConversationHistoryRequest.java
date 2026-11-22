// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-history request. Protocol v12; authority: local-admin. */
public final class ConversationHistoryRequest implements WireValue {
    private final UInt64 beforeSeq;
    private final String conversation;
    private final long limit;

    private ConversationHistoryRequest(Builder builder) {
        if (!builder.beforeSeqSet) throw new IllegalArgumentException("before_seq is required");
        this.beforeSeq = Wire.nonNull(builder.beforeSeq, "before_seq");
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.limitSet) throw new IllegalArgumentException("limit is required");
        this.limit = builder.limit;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 beforeSeq() { return beforeSeq; }
    public String conversation() { return conversation; }
    public long limit() { return limit; }

    public static ConversationHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationHistoryRequest");
        Builder builder = builder();
        Object rawBeforeSeq = Wire.required(object, "before_seq");
        builder.beforeSeq(Wire.uint64(rawBeforeSeq, "ConversationHistoryRequest.before_seq"));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationHistoryRequest.conversation"));
        Object rawLimit = Wire.required(object, "limit");
        builder.limit(Wire.uint32(rawLimit, "ConversationHistoryRequest.limit"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "before_seq", beforeSeq);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "limit", limit);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationHistoryRequest that)) return false;
        return Objects.equals(beforeSeq, that.beforeSeq) && Objects.equals(conversation, that.conversation) && Objects.equals(limit, that.limit);
    }

    @Override
    public int hashCode() { return Objects.hash(beforeSeq, conversation, limit); }

    @Override
    public String toString() { return "ConversationHistoryRequest" + toWire(); }

    public static final class Builder {
        private UInt64 beforeSeq;
        private boolean beforeSeqSet;
        private String conversation;
        private boolean conversationSet;
        private Long limit;
        private boolean limitSet;

        public Builder beforeSeq(UInt64 value) {
            this.beforeSeq = value;
            this.beforeSeqSet = true;
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder limit(long value) {
            this.limit = value;
            this.limitSet = true;
            return this;
        }
        public ConversationHistoryRequest build() { return new ConversationHistoryRequest(this); }
    }
}

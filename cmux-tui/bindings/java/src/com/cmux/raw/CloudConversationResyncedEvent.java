// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-resynced event. Protocol v12; streams: subscribe. */
public final class CloudConversationResyncedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    private final String conversation;
    private final Object messages;
    private final UInt64 rev;
    private final UInt64 seq;
    private final Object summary;

    private CloudConversationResyncedEvent(Builder builder) {
        this.account = builder.account;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = builder.messages == null ? null : Wire.immutableJson(builder.messages);
        if (!builder.revSet) throw new IllegalArgumentException("rev is required");
        this.rev = Wire.nonNull(builder.rev, "rev");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.summarySet) throw new IllegalArgumentException("summary is required");
        this.summary = builder.summary == null ? null : Wire.immutableJson(builder.summary);
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public String conversation() { return conversation; }
    public Object messages() { return messages; }
    public UInt64 rev() { return rev; }
    public UInt64 seq() { return seq; }
    public Object summary() { return summary; }
    @Override public String event() { return "cloud-conversation-resynced"; }

    public static CloudConversationResyncedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationResyncedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-conversation-resynced", "CloudConversationResyncedEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudConversationResyncedEvent.account"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationResyncedEvent.conversation"));
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(rawMessages == null ? null : Wire.immutableJson(rawMessages));
        Object rawRev = Wire.required(object, "rev");
        builder.rev(Wire.uint64(rawRev, "CloudConversationResyncedEvent.rev"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudConversationResyncedEvent.seq"));
        Object rawSummary = Wire.required(object, "summary");
        builder.summary(rawSummary == null ? null : Wire.immutableJson(rawSummary));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-conversation-resynced");
        Wire.put(object, "account", account);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "messages", messages);
        Wire.put(object, "rev", rev);
        Wire.put(object, "seq", seq);
        Wire.put(object, "summary", summary);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationResyncedEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(conversation, that.conversation) && Objects.equals(messages, that.messages) && Objects.equals(rev, that.rev) && Objects.equals(seq, that.seq) && Objects.equals(summary, that.summary);
    }

    @Override
    public int hashCode() { return Objects.hash(account, conversation, messages, rev, seq, summary); }

    @Override
    public String toString() { return "CloudConversationResyncedEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Object messages;
        private boolean messagesSet;
        private UInt64 rev;
        private boolean revSet;
        private UInt64 seq;
        private boolean seqSet;
        private Object summary;
        private boolean summarySet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder messages(Object value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public Builder rev(UInt64 value) {
            this.rev = value;
            this.revSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder summary(Object value) {
            this.summary = value;
            this.summarySet = true;
            return this;
        }
        public CloudConversationResyncedEvent build() { return new CloudConversationResyncedEvent(this); }
    }
}

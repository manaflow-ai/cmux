// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-changed event. Protocol v12; streams: subscribe. */
public final class CloudConversationChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Object change;
    private final String conversation;
    private final UInt64 rev;
    private final UInt64 seq;
    private final String transaction;

    private CloudConversationChangedEvent(Builder builder) {
        if (!builder.changeSet) throw new IllegalArgumentException("change is required");
        this.change = builder.change == null ? null : Wire.immutableJson(builder.change);
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.revSet) throw new IllegalArgumentException("rev is required");
        this.rev = Wire.nonNull(builder.rev, "rev");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.transactionSet) throw new IllegalArgumentException("transaction is required");
        this.transaction = Wire.nonNull(builder.transaction, "transaction");
    }

    public static Builder builder() { return new Builder(); }

    public Object change() { return change; }
    public String conversation() { return conversation; }
    public UInt64 rev() { return rev; }
    public UInt64 seq() { return seq; }
    public String transaction() { return transaction; }
    @Override public String event() { return "cloud-conversation-changed"; }

    public static CloudConversationChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-conversation-changed", "CloudConversationChangedEvent.event");
        Object rawChange = Wire.required(object, "change");
        builder.change(rawChange == null ? null : Wire.immutableJson(rawChange));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationChangedEvent.conversation"));
        Object rawRev = Wire.required(object, "rev");
        builder.rev(Wire.uint64(rawRev, "CloudConversationChangedEvent.rev"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudConversationChangedEvent.seq"));
        Object rawTransaction = Wire.required(object, "transaction");
        builder.transaction(Wire.string(rawTransaction, "CloudConversationChangedEvent.transaction"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-conversation-changed");
        Wire.put(object, "change", change);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "rev", rev);
        Wire.put(object, "seq", seq);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationChangedEvent that)) return false;
        return Objects.equals(change, that.change) && Objects.equals(conversation, that.conversation) && Objects.equals(rev, that.rev) && Objects.equals(seq, that.seq) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(change, conversation, rev, seq, transaction); }

    @Override
    public String toString() { return "CloudConversationChangedEvent" + toWire(); }

    public static final class Builder {
        private Object change;
        private boolean changeSet;
        private String conversation;
        private boolean conversationSet;
        private UInt64 rev;
        private boolean revSet;
        private UInt64 seq;
        private boolean seqSet;
        private String transaction;
        private boolean transactionSet;

        public Builder change(Object value) {
            this.change = value;
            this.changeSet = true;
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
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
        public Builder transaction(String value) {
            this.transaction = value;
            this.transactionSet = true;
            return this;
        }
        public CloudConversationChangedEvent build() { return new CloudConversationChangedEvent(this); }
    }
}

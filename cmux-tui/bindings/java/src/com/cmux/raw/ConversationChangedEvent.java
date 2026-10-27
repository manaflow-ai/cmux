// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-changed event. Protocol v12; streams: subscribe. */
public final class ConversationChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final Object change;
    private final String conversation;
    private final UInt64 rev;
    private final String transaction;

    private ConversationChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.changeSet) throw new IllegalArgumentException("change is required");
        this.change = builder.change == null ? null : Wire.immutableJson(builder.change);
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.revSet) throw new IllegalArgumentException("rev is required");
        this.rev = Wire.nonNull(builder.rev, "rev");
        if (!builder.transactionSet) throw new IllegalArgumentException("transaction is required");
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public Object change() { return change; }
    public String conversation() { return conversation; }
    public UInt64 rev() { return rev; }
    public String transaction() { return transaction; }
    @Override public String event() { return "conversation-changed"; }

    public static ConversationChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-changed", "ConversationChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawChange = Wire.required(object, "change");
        builder.change(rawChange == null ? null : Wire.immutableJson(rawChange));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationChangedEvent.conversation"));
        Object rawRev = Wire.required(object, "rev");
        builder.rev(Wire.uint64(rawRev, "ConversationChangedEvent.rev"));
        Object rawTransaction = Wire.required(object, "transaction");
        builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "ConversationChangedEvent.transaction"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-changed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "change", change);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "rev", rev);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(change, that.change) && Objects.equals(conversation, that.conversation) && Objects.equals(rev, that.rev) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, change, conversation, rev, transaction); }

    @Override
    public String toString() { return "ConversationChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private Object change;
        private boolean changeSet;
        private String conversation;
        private boolean conversationSet;
        private UInt64 rev;
        private boolean revSet;
        private String transaction;
        private boolean transactionSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
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
        public Builder transaction(String value) {
            this.transaction = value;
            this.transactionSet = true;
            return this;
        }
        public ConversationChangedEvent build() { return new ConversationChangedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-inbox-op request. Protocol v12; authority: local-admin. */
public final class ConversationInboxOpRequest implements WireValue {
    private final String conversation;
    private final Object op;

    private ConversationInboxOpRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = builder.op == null ? null : Wire.immutableJson(builder.op);
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public Object op() { return op; }

    public static ConversationInboxOpRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationInboxOpRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationInboxOpRequest.conversation"));
        Object rawOp = Wire.required(object, "op");
        builder.op(rawOp == null ? null : Wire.immutableJson(rawOp));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "op", op);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationInboxOpRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(op, that.op);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, op); }

    @Override
    public String toString() { return "ConversationInboxOpRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Object op;
        private boolean opSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder op(Object value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public ConversationInboxOpRequest build() { return new ConversationInboxOpRequest(this); }
    }
}

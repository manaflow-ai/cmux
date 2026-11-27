// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-op request. Protocol v12; authority: local-admin. */
public final class ConversationOpRequest implements WireValue {
    private final Field<String> actor;
    private final String conversation;
    private final String idempotencyKey;
    private final Object op;
    private final Field<String> transaction;

    private ConversationOpRequest(Builder builder) {
        this.actor = builder.actor;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.idempotencyKeySet) throw new IllegalArgumentException("idempotency_key is required");
        this.idempotencyKey = Wire.nonNull(builder.idempotencyKey, "idempotency_key");
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = builder.op == null ? null : Wire.immutableJson(builder.op);
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> actor() { return actor; }
    public String conversation() { return conversation; }
    public String idempotencyKey() { return idempotencyKey; }
    public Object op() { return op; }
    public Field<String> transaction() { return transaction; }

    public static ConversationOpRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationOpRequest");
        Builder builder = builder();
        Object rawActor = Wire.optional(object, "actor");
        if (!Wire.isMissing(rawActor)) {
            builder.actor(rawActor == null ? null : Wire.string(rawActor, "ConversationOpRequest.actor"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationOpRequest.conversation"));
        Object rawIdempotencyKey = Wire.required(object, "idempotency_key");
        builder.idempotencyKey(Wire.string(rawIdempotencyKey, "ConversationOpRequest.idempotency_key"));
        Object rawOp = Wire.required(object, "op");
        builder.op(rawOp == null ? null : Wire.immutableJson(rawOp));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "ConversationOpRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "actor", actor);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "op", op);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationOpRequest that)) return false;
        return Objects.equals(actor, that.actor) && Objects.equals(conversation, that.conversation) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(op, that.op) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(actor, conversation, idempotencyKey, op, transaction); }

    @Override
    public String toString() { return "ConversationOpRequest" + toWire(); }

    public static final class Builder {
        private Field<String> actor = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private String idempotencyKey;
        private boolean idempotencyKeySet;
        private Object op;
        private boolean opSet;
        private Field<String> transaction = Field.omitted();

        public Builder actor(String value) {
            this.actor = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = value;
            this.idempotencyKeySet = true;
            return this;
        }
        public Builder op(Object value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public ConversationOpRequest build() { return new ConversationOpRequest(this); }
    }
}

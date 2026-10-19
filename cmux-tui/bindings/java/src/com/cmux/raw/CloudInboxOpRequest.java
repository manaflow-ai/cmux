// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-inbox-op request. Protocol v12; authority: local-admin. */
public final class CloudInboxOpRequest implements WireValue {
    private final String conversation;
    private final String idempotencyKey;
    private final Object op;

    private CloudInboxOpRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.idempotencyKeySet) throw new IllegalArgumentException("idempotency_key is required");
        this.idempotencyKey = Wire.nonNull(builder.idempotencyKey, "idempotency_key");
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = builder.op == null ? null : Wire.immutableJson(builder.op);
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public String idempotencyKey() { return idempotencyKey; }
    public Object op() { return op; }

    public static CloudInboxOpRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudInboxOpRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudInboxOpRequest.conversation"));
        Object rawIdempotencyKey = Wire.required(object, "idempotency_key");
        builder.idempotencyKey(Wire.string(rawIdempotencyKey, "CloudInboxOpRequest.idempotency_key"));
        Object rawOp = Wire.required(object, "op");
        builder.op(rawOp == null ? null : Wire.immutableJson(rawOp));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "op", op);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudInboxOpRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(op, that.op);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, idempotencyKey, op); }

    @Override
    public String toString() { return "CloudInboxOpRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private String idempotencyKey;
        private boolean idempotencyKeySet;
        private Object op;
        private boolean opSet;

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
        public CloudInboxOpRequest build() { return new CloudInboxOpRequest(this); }
    }
}

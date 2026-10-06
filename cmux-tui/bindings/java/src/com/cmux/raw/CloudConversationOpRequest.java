// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-op request. Protocol v12; authority: local-admin. */
public final class CloudConversationOpRequest implements WireValue {
    private final Field<String> conversation;
    private final String idempotencyKey;
    private final Object op;
    private final Field<String> origin;

    private CloudConversationOpRequest(Builder builder) {
        this.conversation = builder.conversation;
        if (!builder.idempotencyKeySet) throw new IllegalArgumentException("idempotency_key is required");
        this.idempotencyKey = Wire.nonNull(builder.idempotencyKey, "idempotency_key");
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = builder.op == null ? null : Wire.immutableJson(builder.op);
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> conversation() { return conversation; }
    public String idempotencyKey() { return idempotencyKey; }
    public Object op() { return op; }
    public Field<String> origin() { return origin; }

    public static CloudConversationOpRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationOpRequest");
        Builder builder = builder();
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : Wire.string(rawConversation, "CloudConversationOpRequest.conversation"));
        }
        Object rawIdempotencyKey = Wire.required(object, "idempotency_key");
        builder.idempotencyKey(Wire.string(rawIdempotencyKey, "CloudConversationOpRequest.idempotency_key"));
        Object rawOp = Wire.required(object, "op");
        builder.op(rawOp == null ? null : Wire.immutableJson(rawOp));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CloudConversationOpRequest.origin"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "op", op);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationOpRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(op, that.op) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, idempotencyKey, op, origin); }

    @Override
    public String toString() { return "CloudConversationOpRequest" + toWire(); }

    public static final class Builder {
        private Field<String> conversation = Field.omitted();
        private String idempotencyKey;
        private boolean idempotencyKeySet;
        private Object op;
        private boolean opSet;
        private Field<String> origin = Field.omitted();

        public Builder conversation(String value) {
            this.conversation = Field.ofNullable(value);
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
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public CloudConversationOpRequest build() { return new CloudConversationOpRequest(this); }
    }
}

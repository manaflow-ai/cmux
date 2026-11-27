// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-attachment-read request. Protocol v12; authority: local-admin. */
public final class ConversationAttachmentReadRequest implements WireValue {
    private final String conversation;
    private final String hash;
    private final Field<UInt64> length;
    private final Field<UInt64> offset;
    private final Field<String> variant;

    private ConversationAttachmentReadRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.hashSet) throw new IllegalArgumentException("hash is required");
        this.hash = Wire.nonNull(builder.hash, "hash");
        this.length = builder.length;
        this.offset = builder.offset;
        this.variant = builder.variant;
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public String hash() { return hash; }
    public Field<UInt64> length() { return length; }
    public Field<UInt64> offset() { return offset; }
    public Field<String> variant() { return variant; }

    public static ConversationAttachmentReadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentReadRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationAttachmentReadRequest.conversation"));
        Object rawHash = Wire.required(object, "hash");
        builder.hash(Wire.string(rawHash, "ConversationAttachmentReadRequest.hash"));
        Object rawLength = Wire.optional(object, "length");
        if (!Wire.isMissing(rawLength)) {
            builder.length(rawLength == null ? null : Wire.uint64(rawLength, "ConversationAttachmentReadRequest.length"));
        }
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(rawOffset == null ? null : Wire.uint64(rawOffset, "ConversationAttachmentReadRequest.offset"));
        }
        Object rawVariant = Wire.optional(object, "variant");
        if (!Wire.isMissing(rawVariant)) {
            builder.variant(rawVariant == null ? null : Wire.string(rawVariant, "ConversationAttachmentReadRequest.variant"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "hash", hash);
        Wire.put(object, "length", length);
        Wire.put(object, "offset", offset);
        Wire.put(object, "variant", variant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentReadRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(hash, that.hash) && Objects.equals(length, that.length) && Objects.equals(offset, that.offset) && Objects.equals(variant, that.variant);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, hash, length, offset, variant); }

    @Override
    public String toString() { return "ConversationAttachmentReadRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private String hash;
        private boolean hashSet;
        private Field<UInt64> length = Field.omitted();
        private Field<UInt64> offset = Field.omitted();
        private Field<String> variant = Field.omitted();

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder hash(String value) {
            this.hash = value;
            this.hashSet = true;
            return this;
        }
        public Builder length(UInt64 value) {
            this.length = Field.ofNullable(value);
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = Field.ofNullable(value);
            return this;
        }
        public Builder variant(String value) {
            this.variant = Field.ofNullable(value);
            return this;
        }
        public ConversationAttachmentReadRequest build() { return new ConversationAttachmentReadRequest(this); }
    }
}

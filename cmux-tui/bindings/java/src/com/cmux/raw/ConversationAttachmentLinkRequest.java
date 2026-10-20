// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-attachment-link request. Protocol v12; authority: local-admin. */
public final class ConversationAttachmentLinkRequest implements WireValue {
    private final String conversation;
    private final String hash;
    private final Field<String> name;
    private final Field<String> variant;

    private ConversationAttachmentLinkRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.hashSet) throw new IllegalArgumentException("hash is required");
        this.hash = Wire.nonNull(builder.hash, "hash");
        this.name = builder.name;
        this.variant = builder.variant;
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public String hash() { return hash; }
    public Field<String> name() { return name; }
    public Field<String> variant() { return variant; }

    public static ConversationAttachmentLinkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentLinkRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationAttachmentLinkRequest.conversation"));
        Object rawHash = Wire.required(object, "hash");
        builder.hash(Wire.string(rawHash, "ConversationAttachmentLinkRequest.hash"));
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "ConversationAttachmentLinkRequest.name"));
        }
        Object rawVariant = Wire.optional(object, "variant");
        if (!Wire.isMissing(rawVariant)) {
            builder.variant(rawVariant == null ? null : Wire.string(rawVariant, "ConversationAttachmentLinkRequest.variant"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "hash", hash);
        Wire.put(object, "name", name);
        Wire.put(object, "variant", variant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentLinkRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(hash, that.hash) && Objects.equals(name, that.name) && Objects.equals(variant, that.variant);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, hash, name, variant); }

    @Override
    public String toString() { return "ConversationAttachmentLinkRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private String hash;
        private boolean hashSet;
        private Field<String> name = Field.omitted();
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
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder variant(String value) {
            this.variant = Field.ofNullable(value);
            return this;
        }
        public ConversationAttachmentLinkRequest build() { return new ConversationAttachmentLinkRequest(this); }
    }
}

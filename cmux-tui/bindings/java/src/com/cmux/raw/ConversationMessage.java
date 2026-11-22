// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationMessage implements WireValue {
    private final String author;
    private final String clientMsgId;
    private final String conversation;
    private final String createdAt;
    private final Field<String> editedAt;
    private final String id;
    private final List<ConversationPart> parts;
    private final List<ConversationReaction> reactions;
    private final Field<ConversationPartRef> replyTo;
    private final Field<String> retractedAt;
    private final UInt64 seq;

    private ConversationMessage(Builder builder) {
        if (!builder.authorSet) throw new IllegalArgumentException("author is required");
        this.author = Wire.nonNull(builder.author, "author");
        if (!builder.clientMsgIdSet) throw new IllegalArgumentException("client_msg_id is required");
        this.clientMsgId = Wire.nonNull(builder.clientMsgId, "client_msg_id");
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.createdAtSet) throw new IllegalArgumentException("created_at is required");
        this.createdAt = Wire.nonNull(builder.createdAt, "created_at");
        this.editedAt = builder.editedAt;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.partsSet) throw new IllegalArgumentException("parts is required");
        this.parts = List.copyOf(Wire.nonNull(builder.parts, "parts"));
        if (!builder.reactionsSet) throw new IllegalArgumentException("reactions is required");
        this.reactions = List.copyOf(Wire.nonNull(builder.reactions, "reactions"));
        this.replyTo = builder.replyTo;
        this.retractedAt = builder.retractedAt;
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public String author() { return author; }
    public String clientMsgId() { return clientMsgId; }
    public String conversation() { return conversation; }
    public String createdAt() { return createdAt; }
    public Field<String> editedAt() { return editedAt; }
    public String id() { return id; }
    public List<ConversationPart> parts() { return parts; }
    public List<ConversationReaction> reactions() { return reactions; }
    public Field<ConversationPartRef> replyTo() { return replyTo; }
    public Field<String> retractedAt() { return retractedAt; }
    public UInt64 seq() { return seq; }

    public static ConversationMessage fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationMessage");
        Builder builder = builder();
        Object rawAuthor = Wire.required(object, "author");
        builder.author(Wire.string(rawAuthor, "ConversationMessage.author"));
        Object rawClientMsgId = Wire.required(object, "client_msg_id");
        builder.clientMsgId(Wire.string(rawClientMsgId, "ConversationMessage.client_msg_id"));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationMessage.conversation"));
        Object rawCreatedAt = Wire.required(object, "created_at");
        builder.createdAt(Wire.string(rawCreatedAt, "ConversationMessage.created_at"));
        Object rawEditedAt = Wire.optional(object, "edited_at");
        if (!Wire.isMissing(rawEditedAt)) {
            builder.editedAt(Wire.string(rawEditedAt, "ConversationMessage.edited_at"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "ConversationMessage.id"));
        Object rawParts = Wire.required(object, "parts");
        builder.parts(Wire.array(rawParts, "ConversationMessage.parts", item -> ConversationPart.fromWire(item)));
        Object rawReactions = Wire.required(object, "reactions");
        builder.reactions(Wire.array(rawReactions, "ConversationMessage.reactions", item -> ConversationReaction.fromWire(item)));
        Object rawReplyTo = Wire.optional(object, "reply_to");
        if (!Wire.isMissing(rawReplyTo)) {
            builder.replyTo(ConversationPartRef.fromWire(rawReplyTo));
        }
        Object rawRetractedAt = Wire.optional(object, "retracted_at");
        if (!Wire.isMissing(rawRetractedAt)) {
            builder.retractedAt(Wire.string(rawRetractedAt, "ConversationMessage.retracted_at"));
        }
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "ConversationMessage.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "author", author);
        Wire.put(object, "client_msg_id", clientMsgId);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "created_at", createdAt);
        Wire.put(object, "edited_at", editedAt);
        Wire.put(object, "id", id);
        Wire.put(object, "parts", parts);
        Wire.put(object, "reactions", reactions);
        Wire.put(object, "reply_to", replyTo);
        Wire.put(object, "retracted_at", retractedAt);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationMessage that)) return false;
        return Objects.equals(author, that.author) && Objects.equals(clientMsgId, that.clientMsgId) && Objects.equals(conversation, that.conversation) && Objects.equals(createdAt, that.createdAt) && Objects.equals(editedAt, that.editedAt) && Objects.equals(id, that.id) && Objects.equals(parts, that.parts) && Objects.equals(reactions, that.reactions) && Objects.equals(replyTo, that.replyTo) && Objects.equals(retractedAt, that.retractedAt) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(author, clientMsgId, conversation, createdAt, editedAt, id, parts, reactions, replyTo, retractedAt, seq); }

    @Override
    public String toString() { return "ConversationMessage" + toWire(); }

    public static final class Builder {
        private String author;
        private boolean authorSet;
        private String clientMsgId;
        private boolean clientMsgIdSet;
        private String conversation;
        private boolean conversationSet;
        private String createdAt;
        private boolean createdAtSet;
        private Field<String> editedAt = Field.omitted();
        private String id;
        private boolean idSet;
        private List<ConversationPart> parts;
        private boolean partsSet;
        private List<ConversationReaction> reactions;
        private boolean reactionsSet;
        private Field<ConversationPartRef> replyTo = Field.omitted();
        private Field<String> retractedAt = Field.omitted();
        private UInt64 seq;
        private boolean seqSet;

        public Builder author(String value) {
            this.author = value;
            this.authorSet = true;
            return this;
        }
        public Builder clientMsgId(String value) {
            this.clientMsgId = value;
            this.clientMsgIdSet = true;
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder createdAt(String value) {
            this.createdAt = value;
            this.createdAtSet = true;
            return this;
        }
        public Builder editedAt(String value) {
            this.editedAt = Field.of(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder parts(List<ConversationPart> value) {
            this.parts = value;
            this.partsSet = true;
            return this;
        }
        public Builder reactions(List<ConversationReaction> value) {
            this.reactions = value;
            this.reactionsSet = true;
            return this;
        }
        public Builder replyTo(ConversationPartRef value) {
            this.replyTo = Field.of(value);
            return this;
        }
        public Builder retractedAt(String value) {
            this.retractedAt = Field.of(value);
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public ConversationMessage build() { return new ConversationMessage(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationSearchHit implements WireValue {
    private final String author;
    private final String conversation;
    private final String createdAt;
    private final String messageId;
    private final UInt64 seq;
    private final String snippet;
    private final String title;

    private ConversationSearchHit(Builder builder) {
        if (!builder.authorSet) throw new IllegalArgumentException("author is required");
        this.author = Wire.nonNull(builder.author, "author");
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.createdAtSet) throw new IllegalArgumentException("created_at is required");
        this.createdAt = Wire.nonNull(builder.createdAt, "created_at");
        if (!builder.messageIdSet) throw new IllegalArgumentException("message_id is required");
        this.messageId = Wire.nonNull(builder.messageId, "message_id");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.snippetSet) throw new IllegalArgumentException("snippet is required");
        this.snippet = Wire.nonNull(builder.snippet, "snippet");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String author() { return author; }
    public String conversation() { return conversation; }
    public String createdAt() { return createdAt; }
    public String messageId() { return messageId; }
    public UInt64 seq() { return seq; }
    public String snippet() { return snippet; }
    public String title() { return title; }

    public static ConversationSearchHit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationSearchHit");
        Builder builder = builder();
        Object rawAuthor = Wire.required(object, "author");
        builder.author(Wire.string(rawAuthor, "ConversationSearchHit.author"));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationSearchHit.conversation"));
        Object rawCreatedAt = Wire.required(object, "created_at");
        builder.createdAt(Wire.string(rawCreatedAt, "ConversationSearchHit.created_at"));
        Object rawMessageId = Wire.required(object, "message_id");
        builder.messageId(Wire.string(rawMessageId, "ConversationSearchHit.message_id"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "ConversationSearchHit.seq"));
        Object rawSnippet = Wire.required(object, "snippet");
        builder.snippet(Wire.string(rawSnippet, "ConversationSearchHit.snippet"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "ConversationSearchHit.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "author", author);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "created_at", createdAt);
        Wire.put(object, "message_id", messageId);
        Wire.put(object, "seq", seq);
        Wire.put(object, "snippet", snippet);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationSearchHit that)) return false;
        return Objects.equals(author, that.author) && Objects.equals(conversation, that.conversation) && Objects.equals(createdAt, that.createdAt) && Objects.equals(messageId, that.messageId) && Objects.equals(seq, that.seq) && Objects.equals(snippet, that.snippet) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(author, conversation, createdAt, messageId, seq, snippet, title); }

    @Override
    public String toString() { return "ConversationSearchHit" + toWire(); }

    public static final class Builder {
        private String author;
        private boolean authorSet;
        private String conversation;
        private boolean conversationSet;
        private String createdAt;
        private boolean createdAtSet;
        private String messageId;
        private boolean messageIdSet;
        private UInt64 seq;
        private boolean seqSet;
        private String snippet;
        private boolean snippetSet;
        private String title;
        private boolean titleSet;

        public Builder author(String value) {
            this.author = value;
            this.authorSet = true;
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
        public Builder messageId(String value) {
            this.messageId = value;
            this.messageIdSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder snippet(String value) {
            this.snippet = value;
            this.snippetSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public ConversationSearchHit build() { return new ConversationSearchHit(this); }
    }
}

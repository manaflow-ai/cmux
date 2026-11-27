// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationThreadSummary implements WireValue {
    private final List<String> authors;
    private final String lastReplyAt;
    private final UInt64 lastReplySeq;
    private final Field<String> owner;
    private final UInt64 replyCount;
    private final Field<String> resolvedAt;
    private final Field<String> resolvedBy;
    private final String root;
    private final Field<ConversationThreadStatus> status;
    private final Field<String> title;

    private ConversationThreadSummary(Builder builder) {
        if (!builder.authorsSet) throw new IllegalArgumentException("authors is required");
        this.authors = List.copyOf(Wire.nonNull(builder.authors, "authors"));
        if (!builder.lastReplyAtSet) throw new IllegalArgumentException("last_reply_at is required");
        this.lastReplyAt = builder.lastReplyAt;
        if (!builder.lastReplySeqSet) throw new IllegalArgumentException("last_reply_seq is required");
        this.lastReplySeq = builder.lastReplySeq;
        this.owner = builder.owner;
        if (!builder.replyCountSet) throw new IllegalArgumentException("reply_count is required");
        this.replyCount = Wire.nonNull(builder.replyCount, "reply_count");
        this.resolvedAt = builder.resolvedAt;
        this.resolvedBy = builder.resolvedBy;
        if (!builder.rootSet) throw new IllegalArgumentException("root is required");
        this.root = Wire.nonNull(builder.root, "root");
        this.status = builder.status;
        this.title = builder.title;
    }

    public static Builder builder() { return new Builder(); }

    public List<String> authors() { return authors; }
    public String lastReplyAt() { return lastReplyAt; }
    public UInt64 lastReplySeq() { return lastReplySeq; }
    public Field<String> owner() { return owner; }
    public UInt64 replyCount() { return replyCount; }
    public Field<String> resolvedAt() { return resolvedAt; }
    public Field<String> resolvedBy() { return resolvedBy; }
    public String root() { return root; }
    public Field<ConversationThreadStatus> status() { return status; }
    public Field<String> title() { return title; }

    public static ConversationThreadSummary fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationThreadSummary");
        Builder builder = builder();
        Object rawAuthors = Wire.required(object, "authors");
        builder.authors(Wire.array(rawAuthors, "ConversationThreadSummary.authors", item -> Wire.string(item, "ConversationThreadSummary.authors item")));
        Object rawLastReplyAt = Wire.required(object, "last_reply_at");
        builder.lastReplyAt(rawLastReplyAt == null ? null : Wire.string(rawLastReplyAt, "ConversationThreadSummary.last_reply_at"));
        Object rawLastReplySeq = Wire.required(object, "last_reply_seq");
        builder.lastReplySeq(rawLastReplySeq == null ? null : Wire.uint64(rawLastReplySeq, "ConversationThreadSummary.last_reply_seq"));
        Object rawOwner = Wire.optional(object, "owner");
        if (!Wire.isMissing(rawOwner)) {
            builder.owner(Wire.string(rawOwner, "ConversationThreadSummary.owner"));
        }
        Object rawReplyCount = Wire.required(object, "reply_count");
        builder.replyCount(Wire.uint64(rawReplyCount, "ConversationThreadSummary.reply_count"));
        Object rawResolvedAt = Wire.optional(object, "resolved_at");
        if (!Wire.isMissing(rawResolvedAt)) {
            builder.resolvedAt(Wire.string(rawResolvedAt, "ConversationThreadSummary.resolved_at"));
        }
        Object rawResolvedBy = Wire.optional(object, "resolved_by");
        if (!Wire.isMissing(rawResolvedBy)) {
            builder.resolvedBy(Wire.string(rawResolvedBy, "ConversationThreadSummary.resolved_by"));
        }
        Object rawRoot = Wire.required(object, "root");
        builder.root(Wire.string(rawRoot, "ConversationThreadSummary.root"));
        Object rawStatus = Wire.optional(object, "status");
        if (!Wire.isMissing(rawStatus)) {
            builder.status(ConversationThreadStatus.fromWire(rawStatus));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(Wire.string(rawTitle, "ConversationThreadSummary.title"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authors", authors);
        Wire.put(object, "last_reply_at", lastReplyAt);
        Wire.put(object, "last_reply_seq", lastReplySeq);
        Wire.put(object, "owner", owner);
        Wire.put(object, "reply_count", replyCount);
        Wire.put(object, "resolved_at", resolvedAt);
        Wire.put(object, "resolved_by", resolvedBy);
        Wire.put(object, "root", root);
        Wire.put(object, "status", status);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationThreadSummary that)) return false;
        return Objects.equals(authors, that.authors) && Objects.equals(lastReplyAt, that.lastReplyAt) && Objects.equals(lastReplySeq, that.lastReplySeq) && Objects.equals(owner, that.owner) && Objects.equals(replyCount, that.replyCount) && Objects.equals(resolvedAt, that.resolvedAt) && Objects.equals(resolvedBy, that.resolvedBy) && Objects.equals(root, that.root) && Objects.equals(status, that.status) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(authors, lastReplyAt, lastReplySeq, owner, replyCount, resolvedAt, resolvedBy, root, status, title); }

    @Override
    public String toString() { return "ConversationThreadSummary" + toWire(); }

    public static final class Builder {
        private List<String> authors;
        private boolean authorsSet;
        private String lastReplyAt;
        private boolean lastReplyAtSet;
        private UInt64 lastReplySeq;
        private boolean lastReplySeqSet;
        private Field<String> owner = Field.omitted();
        private UInt64 replyCount;
        private boolean replyCountSet;
        private Field<String> resolvedAt = Field.omitted();
        private Field<String> resolvedBy = Field.omitted();
        private String root;
        private boolean rootSet;
        private Field<ConversationThreadStatus> status = Field.omitted();
        private Field<String> title = Field.omitted();

        public Builder authors(List<String> value) {
            this.authors = value;
            this.authorsSet = true;
            return this;
        }
        public Builder lastReplyAt(String value) {
            this.lastReplyAt = value;
            this.lastReplyAtSet = true;
            return this;
        }
        public Builder lastReplySeq(UInt64 value) {
            this.lastReplySeq = value;
            this.lastReplySeqSet = true;
            return this;
        }
        public Builder owner(String value) {
            this.owner = Field.of(value);
            return this;
        }
        public Builder replyCount(UInt64 value) {
            this.replyCount = value;
            this.replyCountSet = true;
            return this;
        }
        public Builder resolvedAt(String value) {
            this.resolvedAt = Field.of(value);
            return this;
        }
        public Builder resolvedBy(String value) {
            this.resolvedBy = Field.of(value);
            return this;
        }
        public Builder root(String value) {
            this.root = value;
            this.rootSet = true;
            return this;
        }
        public Builder status(ConversationThreadStatus value) {
            this.status = Field.of(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.of(value);
            return this;
        }
        public ConversationThreadSummary build() { return new ConversationThreadSummary(this); }
    }
}

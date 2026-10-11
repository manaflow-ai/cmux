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
    private final UInt64 replyCount;
    private final String root;

    private ConversationThreadSummary(Builder builder) {
        if (!builder.authorsSet) throw new IllegalArgumentException("authors is required");
        this.authors = List.copyOf(Wire.nonNull(builder.authors, "authors"));
        if (!builder.lastReplyAtSet) throw new IllegalArgumentException("last_reply_at is required");
        this.lastReplyAt = builder.lastReplyAt;
        if (!builder.lastReplySeqSet) throw new IllegalArgumentException("last_reply_seq is required");
        this.lastReplySeq = builder.lastReplySeq;
        if (!builder.replyCountSet) throw new IllegalArgumentException("reply_count is required");
        this.replyCount = Wire.nonNull(builder.replyCount, "reply_count");
        if (!builder.rootSet) throw new IllegalArgumentException("root is required");
        this.root = Wire.nonNull(builder.root, "root");
    }

    public static Builder builder() { return new Builder(); }

    public List<String> authors() { return authors; }
    public String lastReplyAt() { return lastReplyAt; }
    public UInt64 lastReplySeq() { return lastReplySeq; }
    public UInt64 replyCount() { return replyCount; }
    public String root() { return root; }

    public static ConversationThreadSummary fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationThreadSummary");
        Builder builder = builder();
        Object rawAuthors = Wire.required(object, "authors");
        builder.authors(Wire.array(rawAuthors, "ConversationThreadSummary.authors", item -> Wire.string(item, "ConversationThreadSummary.authors item")));
        Object rawLastReplyAt = Wire.required(object, "last_reply_at");
        builder.lastReplyAt(rawLastReplyAt == null ? null : Wire.string(rawLastReplyAt, "ConversationThreadSummary.last_reply_at"));
        Object rawLastReplySeq = Wire.required(object, "last_reply_seq");
        builder.lastReplySeq(rawLastReplySeq == null ? null : Wire.uint64(rawLastReplySeq, "ConversationThreadSummary.last_reply_seq"));
        Object rawReplyCount = Wire.required(object, "reply_count");
        builder.replyCount(Wire.uint64(rawReplyCount, "ConversationThreadSummary.reply_count"));
        Object rawRoot = Wire.required(object, "root");
        builder.root(Wire.string(rawRoot, "ConversationThreadSummary.root"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authors", authors);
        Wire.put(object, "last_reply_at", lastReplyAt);
        Wire.put(object, "last_reply_seq", lastReplySeq);
        Wire.put(object, "reply_count", replyCount);
        Wire.put(object, "root", root);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationThreadSummary that)) return false;
        return Objects.equals(authors, that.authors) && Objects.equals(lastReplyAt, that.lastReplyAt) && Objects.equals(lastReplySeq, that.lastReplySeq) && Objects.equals(replyCount, that.replyCount) && Objects.equals(root, that.root);
    }

    @Override
    public int hashCode() { return Objects.hash(authors, lastReplyAt, lastReplySeq, replyCount, root); }

    @Override
    public String toString() { return "ConversationThreadSummary" + toWire(); }

    public static final class Builder {
        private List<String> authors;
        private boolean authorsSet;
        private String lastReplyAt;
        private boolean lastReplyAtSet;
        private UInt64 lastReplySeq;
        private boolean lastReplySeqSet;
        private UInt64 replyCount;
        private boolean replyCountSet;
        private String root;
        private boolean rootSet;

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
        public Builder replyCount(UInt64 value) {
            this.replyCount = value;
            this.replyCountSet = true;
            return this;
        }
        public Builder root(String value) {
            this.root = value;
            this.rootSet = true;
            return this;
        }
        public ConversationThreadSummary build() { return new ConversationThreadSummary(this); }
    }
}

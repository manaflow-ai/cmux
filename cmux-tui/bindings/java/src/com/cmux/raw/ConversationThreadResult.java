// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationThreadResult implements WireValue {
    private final boolean hasMore;
    private final List<ConversationMessage> replies;
    private final ConversationMessage root;
    private final ConversationThreadSummary thread;

    private ConversationThreadResult(Builder builder) {
        if (!builder.hasMoreSet) throw new IllegalArgumentException("has_more is required");
        this.hasMore = builder.hasMore;
        if (!builder.repliesSet) throw new IllegalArgumentException("replies is required");
        this.replies = List.copyOf(Wire.nonNull(builder.replies, "replies"));
        if (!builder.rootSet) throw new IllegalArgumentException("root is required");
        this.root = Wire.nonNull(builder.root, "root");
        if (!builder.threadSet) throw new IllegalArgumentException("thread is required");
        this.thread = Wire.nonNull(builder.thread, "thread");
    }

    public static Builder builder() { return new Builder(); }

    public boolean hasMore() { return hasMore; }
    public List<ConversationMessage> replies() { return replies; }
    public ConversationMessage root() { return root; }
    public ConversationThreadSummary thread() { return thread; }

    public static ConversationThreadResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationThreadResult");
        Builder builder = builder();
        Object rawHasMore = Wire.required(object, "has_more");
        builder.hasMore(Wire.bool(rawHasMore, "ConversationThreadResult.has_more"));
        Object rawReplies = Wire.required(object, "replies");
        builder.replies(Wire.array(rawReplies, "ConversationThreadResult.replies", item -> ConversationMessage.fromWire(item)));
        Object rawRoot = Wire.required(object, "root");
        builder.root(ConversationMessage.fromWire(rawRoot));
        Object rawThread = Wire.required(object, "thread");
        builder.thread(ConversationThreadSummary.fromWire(rawThread));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "has_more", hasMore);
        Wire.put(object, "replies", replies);
        Wire.put(object, "root", root);
        Wire.put(object, "thread", thread);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationThreadResult that)) return false;
        return Objects.equals(hasMore, that.hasMore) && Objects.equals(replies, that.replies) && Objects.equals(root, that.root) && Objects.equals(thread, that.thread);
    }

    @Override
    public int hashCode() { return Objects.hash(hasMore, replies, root, thread); }

    @Override
    public String toString() { return "ConversationThreadResult" + toWire(); }

    public static final class Builder {
        private Boolean hasMore;
        private boolean hasMoreSet;
        private List<ConversationMessage> replies;
        private boolean repliesSet;
        private ConversationMessage root;
        private boolean rootSet;
        private ConversationThreadSummary thread;
        private boolean threadSet;

        public Builder hasMore(boolean value) {
            this.hasMore = value;
            this.hasMoreSet = true;
            return this;
        }
        public Builder replies(List<ConversationMessage> value) {
            this.replies = value;
            this.repliesSet = true;
            return this;
        }
        public Builder root(ConversationMessage value) {
            this.root = value;
            this.rootSet = true;
            return this;
        }
        public Builder thread(ConversationThreadSummary value) {
            this.thread = value;
            this.threadSet = true;
            return this;
        }
        public ConversationThreadResult build() { return new ConversationThreadResult(this); }
    }
}

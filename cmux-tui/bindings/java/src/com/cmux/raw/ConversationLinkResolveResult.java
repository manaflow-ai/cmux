// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationLinkResolveResult implements WireValue {
    private final ConversationSummary conversation;
    private final Field<ConversationMessage> message;
    private final List<String> path;
    private final Field<String> threadRoot;
    private final Field<Boolean> truncated;
    private final String url;

    private ConversationLinkResolveResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.message = builder.message;
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = List.copyOf(Wire.nonNull(builder.path, "path"));
        this.threadRoot = builder.threadRoot;
        this.truncated = builder.truncated;
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public ConversationSummary conversation() { return conversation; }
    public Field<ConversationMessage> message() { return message; }
    public List<String> path() { return path; }
    public Field<String> threadRoot() { return threadRoot; }
    public Field<Boolean> truncated() { return truncated; }
    public String url() { return url; }

    public static ConversationLinkResolveResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationLinkResolveResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationSummary.fromWire(rawConversation));
        Object rawMessage = Wire.optional(object, "message");
        if (!Wire.isMissing(rawMessage)) {
            builder.message(ConversationMessage.fromWire(rawMessage));
        }
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.array(rawPath, "ConversationLinkResolveResult.path", item -> Wire.string(item, "ConversationLinkResolveResult.path item")));
        Object rawThreadRoot = Wire.optional(object, "thread_root");
        if (!Wire.isMissing(rawThreadRoot)) {
            builder.threadRoot(Wire.string(rawThreadRoot, "ConversationLinkResolveResult.thread_root"));
        }
        Object rawTruncated = Wire.optional(object, "truncated");
        if (!Wire.isMissing(rawTruncated)) {
            builder.truncated(Wire.bool(rawTruncated, "ConversationLinkResolveResult.truncated"));
        }
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "ConversationLinkResolveResult.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "message", message);
        Wire.put(object, "path", path);
        Wire.put(object, "thread_root", threadRoot);
        Wire.put(object, "truncated", truncated);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationLinkResolveResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(message, that.message) && Objects.equals(path, that.path) && Objects.equals(threadRoot, that.threadRoot) && Objects.equals(truncated, that.truncated) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, message, path, threadRoot, truncated, url); }

    @Override
    public String toString() { return "ConversationLinkResolveResult" + toWire(); }

    public static final class Builder {
        private ConversationSummary conversation;
        private boolean conversationSet;
        private Field<ConversationMessage> message = Field.omitted();
        private List<String> path;
        private boolean pathSet;
        private Field<String> threadRoot = Field.omitted();
        private Field<Boolean> truncated = Field.omitted();
        private String url;
        private boolean urlSet;

        public Builder conversation(ConversationSummary value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder message(ConversationMessage value) {
            this.message = Field.of(value);
            return this;
        }
        public Builder path(List<String> value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder threadRoot(String value) {
            this.threadRoot = Field.of(value);
            return this;
        }
        public Builder truncated(Boolean value) {
            this.truncated = Field.of(value);
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public ConversationLinkResolveResult build() { return new ConversationLinkResolveResult(this); }
    }
}

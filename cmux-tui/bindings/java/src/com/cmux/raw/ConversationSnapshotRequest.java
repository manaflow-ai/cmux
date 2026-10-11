// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-snapshot request. Protocol v12; authority: local-admin. */
public final class ConversationSnapshotRequest implements WireValue {
    private final String conversation;
    private final long tail;

    private ConversationSnapshotRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.tailSet) throw new IllegalArgumentException("tail is required");
        this.tail = builder.tail;
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public long tail() { return tail; }

    public static ConversationSnapshotRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationSnapshotRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationSnapshotRequest.conversation"));
        Object rawTail = Wire.required(object, "tail");
        builder.tail(Wire.uint32(rawTail, "ConversationSnapshotRequest.tail"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "tail", tail);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationSnapshotRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(tail, that.tail);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, tail); }

    @Override
    public String toString() { return "ConversationSnapshotRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Long tail;
        private boolean tailSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder tail(long value) {
            this.tail = value;
            this.tailSet = true;
            return this;
        }
        public ConversationSnapshotRequest build() { return new ConversationSnapshotRequest(this); }
    }
}

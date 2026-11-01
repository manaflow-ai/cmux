// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-runs request. Protocol v12; authority: local-admin. */
public final class ConversationRunsRequest implements WireValue {
    private final Field<List<String>> answers;
    private final Field<UInt64> beforeStartedAt;
    private final String conversation;
    private final Field<Long> limit;
    private final Field<List<String>> turns;

    private ConversationRunsRequest(Builder builder) {
        this.answers = builder.answers.map(value -> List.copyOf(value));
        this.beforeStartedAt = builder.beforeStartedAt;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.limit = builder.limit;
        this.turns = builder.turns.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> answers() { return answers; }
    public Field<UInt64> beforeStartedAt() { return beforeStartedAt; }
    public String conversation() { return conversation; }
    public Field<Long> limit() { return limit; }
    public Field<List<String>> turns() { return turns; }

    public static ConversationRunsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationRunsRequest");
        Builder builder = builder();
        Object rawAnswers = Wire.optional(object, "answers");
        if (!Wire.isMissing(rawAnswers)) {
            builder.answers(rawAnswers == null ? null : Wire.array(rawAnswers, "ConversationRunsRequest.answers", item -> Wire.string(item, "ConversationRunsRequest.answers item")));
        }
        Object rawBeforeStartedAt = Wire.optional(object, "before_started_at");
        if (!Wire.isMissing(rawBeforeStartedAt)) {
            builder.beforeStartedAt(rawBeforeStartedAt == null ? null : Wire.uint64(rawBeforeStartedAt, "ConversationRunsRequest.before_started_at"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationRunsRequest.conversation"));
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "ConversationRunsRequest.limit"));
        }
        Object rawTurns = Wire.optional(object, "turns");
        if (!Wire.isMissing(rawTurns)) {
            builder.turns(rawTurns == null ? null : Wire.array(rawTurns, "ConversationRunsRequest.turns", item -> Wire.string(item, "ConversationRunsRequest.turns item")));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "answers", answers);
        Wire.put(object, "before_started_at", beforeStartedAt);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "limit", limit);
        Wire.put(object, "turns", turns);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationRunsRequest that)) return false;
        return Objects.equals(answers, that.answers) && Objects.equals(beforeStartedAt, that.beforeStartedAt) && Objects.equals(conversation, that.conversation) && Objects.equals(limit, that.limit) && Objects.equals(turns, that.turns);
    }

    @Override
    public int hashCode() { return Objects.hash(answers, beforeStartedAt, conversation, limit, turns); }

    @Override
    public String toString() { return "ConversationRunsRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> answers = Field.omitted();
        private Field<UInt64> beforeStartedAt = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Field<Long> limit = Field.omitted();
        private Field<List<String>> turns = Field.omitted();

        public Builder answers(List<String> value) {
            this.answers = Field.ofNullable(value);
            return this;
        }
        public Builder beforeStartedAt(UInt64 value) {
            this.beforeStartedAt = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder limit(Long value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder turns(List<String> value) {
            this.turns = Field.ofNullable(value);
            return this;
        }
        public ConversationRunsRequest build() { return new ConversationRunsRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-question-decision request. Protocol v12; authority: control. */
public final class ConversationQuestionDecisionRequest implements WireValue {
    /** What the person chose; only `selections` is read (the owner sets `respondent` and `answered_at`). */
    private final ConversationQuestionAnswer answer;
    private final String conversation;
    private final String messageId;
    /** true returns only {question}: the stored tool-approval card, for the record after the app answered acpmux natively. */
    private final Field<Boolean> nativeRecord;
    private final UInt64 partIndex;
    /** The stored Question JSON exactly as Home displayed it. Refused `question.stale` unless it parses to the stored question; required unless `native_record` is true. */
    private final Field<Object> question;

    private ConversationQuestionDecisionRequest(Builder builder) {
        if (!builder.answerSet) throw new IllegalArgumentException("answer is required");
        this.answer = Wire.nonNull(builder.answer, "answer");
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.messageIdSet) throw new IllegalArgumentException("message_id is required");
        this.messageId = Wire.nonNull(builder.messageId, "message_id");
        this.nativeRecord = builder.nativeRecord;
        if (!builder.partIndexSet) throw new IllegalArgumentException("part_index is required");
        this.partIndex = Wire.nonNull(builder.partIndex, "part_index");
        this.question = builder.question.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public ConversationQuestionAnswer answer() { return answer; }
    public String conversation() { return conversation; }
    public String messageId() { return messageId; }
    public Field<Boolean> nativeRecord() { return nativeRecord; }
    public UInt64 partIndex() { return partIndex; }
    public Field<Object> question() { return question; }

    public static ConversationQuestionDecisionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationQuestionDecisionRequest");
        Builder builder = builder();
        Object rawAnswer = Wire.required(object, "answer");
        builder.answer(ConversationQuestionAnswer.fromWire(rawAnswer));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationQuestionDecisionRequest.conversation"));
        Object rawMessageId = Wire.required(object, "message_id");
        builder.messageId(Wire.string(rawMessageId, "ConversationQuestionDecisionRequest.message_id"));
        Object rawNativeRecord = Wire.optional(object, "native_record");
        if (!Wire.isMissing(rawNativeRecord)) {
            builder.nativeRecord(Wire.bool(rawNativeRecord, "ConversationQuestionDecisionRequest.native_record"));
        }
        Object rawPartIndex = Wire.required(object, "part_index");
        builder.partIndex(Wire.uint64(rawPartIndex, "ConversationQuestionDecisionRequest.part_index"));
        Object rawQuestion = Wire.optional(object, "question");
        if (!Wire.isMissing(rawQuestion)) {
            builder.question(rawQuestion == null ? null : Wire.immutableJson(rawQuestion));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "answer", answer);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "message_id", messageId);
        Wire.put(object, "native_record", nativeRecord);
        Wire.put(object, "part_index", partIndex);
        Wire.put(object, "question", question);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationQuestionDecisionRequest that)) return false;
        return Objects.equals(answer, that.answer) && Objects.equals(conversation, that.conversation) && Objects.equals(messageId, that.messageId) && Objects.equals(nativeRecord, that.nativeRecord) && Objects.equals(partIndex, that.partIndex) && Objects.equals(question, that.question);
    }

    @Override
    public int hashCode() { return Objects.hash(answer, conversation, messageId, nativeRecord, partIndex, question); }

    @Override
    public String toString() { return "ConversationQuestionDecisionRequest" + toWire(); }

    public static final class Builder {
        private ConversationQuestionAnswer answer;
        private boolean answerSet;
        private String conversation;
        private boolean conversationSet;
        private String messageId;
        private boolean messageIdSet;
        private Field<Boolean> nativeRecord = Field.omitted();
        private UInt64 partIndex;
        private boolean partIndexSet;
        private Field<Object> question = Field.omitted();

        public Builder answer(ConversationQuestionAnswer value) {
            this.answer = value;
            this.answerSet = true;
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder messageId(String value) {
            this.messageId = value;
            this.messageIdSet = true;
            return this;
        }
        public Builder nativeRecord(Boolean value) {
            this.nativeRecord = Field.of(value);
            return this;
        }
        public Builder partIndex(UInt64 value) {
            this.partIndex = value;
            this.partIndexSet = true;
            return this;
        }
        public Builder question(Object value) {
            this.question = Field.ofNullable(value);
            return this;
        }
        public ConversationQuestionDecisionRequest build() { return new ConversationQuestionDecisionRequest(this); }
    }
}

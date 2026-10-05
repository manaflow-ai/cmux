// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationChange implements WireValue {
    /** kind conversation. */
    private final Field<ConversationSummary> conversation;
    /** Known values: message and message-updated (message), read-cursor (participant, seq), conversation (conversation). A change of another kind keeps its fields in the additional properties. */
    private final String kind;
    /** kind message or message-updated. */
    private final Field<ConversationMessage> message;
    /** kind read-cursor. */
    private final Field<String> participant;
    /** kind read-cursor. */
    private final Field<UInt64> seq;
    private final Map<String, Object> additionalProperties;

    private ConversationChange(Builder builder) {
        this.conversation = builder.conversation;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.message = builder.message;
        this.participant = builder.participant;
        this.seq = builder.seq;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<ConversationSummary> conversation() { return conversation; }
    public String kind() { return kind; }
    public Field<ConversationMessage> message() { return message; }
    public Field<String> participant() { return participant; }
    public Field<UInt64> seq() { return seq; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ConversationChange fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationChange");
        Builder builder = builder();
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(ConversationSummary.fromWire(rawConversation));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ConversationChange.kind"));
        Object rawMessage = Wire.optional(object, "message");
        if (!Wire.isMissing(rawMessage)) {
            builder.message(ConversationMessage.fromWire(rawMessage));
        }
        Object rawParticipant = Wire.optional(object, "participant");
        if (!Wire.isMissing(rawParticipant)) {
            builder.participant(Wire.string(rawParticipant, "ConversationChange.participant"));
        }
        Object rawSeq = Wire.optional(object, "seq");
        if (!Wire.isMissing(rawSeq)) {
            builder.seq(Wire.uint64(rawSeq, "ConversationChange.seq"));
        }
        List<String> known = List.of("conversation", "kind", "message", "participant", "seq");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "kind", kind);
        Wire.put(object, "message", message);
        Wire.put(object, "participant", participant);
        Wire.put(object, "seq", seq);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationChange that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(kind, that.kind) && Objects.equals(message, that.message) && Objects.equals(participant, that.participant) && Objects.equals(seq, that.seq) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, kind, message, participant, seq, additionalProperties); }

    @Override
    public String toString() { return "ConversationChange" + toWire(); }

    public static final class Builder {
        private Field<ConversationSummary> conversation = Field.omitted();
        private String kind;
        private boolean kindSet;
        private Field<ConversationMessage> message = Field.omitted();
        private Field<String> participant = Field.omitted();
        private Field<UInt64> seq = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder conversation(ConversationSummary value) {
            this.conversation = Field.of(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder message(ConversationMessage value) {
            this.message = Field.of(value);
            return this;
        }
        public Builder participant(String value) {
            this.participant = Field.of(value);
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ConversationChange build() { return new ConversationChange(this); }
    }
}

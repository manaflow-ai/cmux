// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-scheduled-changed event. Protocol v12; streams: subscribe. */
public final class ConversationScheduledChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String conversation;
    private final String participant;
    private final Field<Object> removed;
    private final Field<Object> scheduled;

    private ConversationScheduledChangedEvent(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        this.removed = builder.removed.map(value -> Wire.immutableJson(value));
        this.scheduled = builder.scheduled.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public String participant() { return participant; }
    public Field<Object> removed() { return removed; }
    public Field<Object> scheduled() { return scheduled; }
    @Override public String event() { return "conversation-scheduled-changed"; }

    public static ConversationScheduledChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationScheduledChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-scheduled-changed", "ConversationScheduledChangedEvent.event");
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationScheduledChangedEvent.conversation"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationScheduledChangedEvent.participant"));
        Object rawRemoved = Wire.optional(object, "removed");
        if (!Wire.isMissing(rawRemoved)) {
            builder.removed(Wire.immutableJson(rawRemoved));
        }
        Object rawScheduled = Wire.optional(object, "scheduled");
        if (!Wire.isMissing(rawScheduled)) {
            builder.scheduled(Wire.immutableJson(rawScheduled));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-scheduled-changed");
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "participant", participant);
        Wire.put(object, "removed", removed);
        Wire.put(object, "scheduled", scheduled);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationScheduledChangedEvent that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(participant, that.participant) && Objects.equals(removed, that.removed) && Objects.equals(scheduled, that.scheduled);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, participant, removed, scheduled); }

    @Override
    public String toString() { return "ConversationScheduledChangedEvent" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private String participant;
        private boolean participantSet;
        private Field<Object> removed = Field.omitted();
        private Field<Object> scheduled = Field.omitted();

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder removed(Object value) {
            this.removed = Field.of(value);
            return this;
        }
        public Builder scheduled(Object value) {
            this.scheduled = Field.of(value);
            return this;
        }
        public ConversationScheduledChangedEvent build() { return new ConversationScheduledChangedEvent(this); }
    }
}

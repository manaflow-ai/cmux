// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-draft event. Protocol v12; streams: subscribe. */
public final class ConversationDraftEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String conversation;
    private final Object item;
    private final String participant;

    private ConversationDraftEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.itemSet) throw new IllegalArgumentException("item is required");
        this.item = Wire.immutableJson(Wire.nonNull(builder.item, "item"));
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public String conversation() { return conversation; }
    public Object item() { return item; }
    public String participant() { return participant; }
    @Override public String event() { return "conversation-draft"; }

    public static ConversationDraftEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationDraftEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-draft", "ConversationDraftEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationDraftEvent.conversation"));
        Object rawItem = Wire.required(object, "item");
        builder.item(Wire.immutableJson(rawItem));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationDraftEvent.participant"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-draft");
        Wire.put(object, "cause", cause);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "item", item);
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationDraftEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(conversation, that.conversation) && Objects.equals(item, that.item) && Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, conversation, item, participant); }

    @Override
    public String toString() { return "ConversationDraftEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Object item;
        private boolean itemSet;
        private String participant;
        private boolean participantSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder item(Object value) {
            this.item = value;
            this.itemSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public ConversationDraftEvent build() { return new ConversationDraftEvent(this); }
    }
}

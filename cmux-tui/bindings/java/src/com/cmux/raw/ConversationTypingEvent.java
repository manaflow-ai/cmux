// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-typing event. Protocol v12; streams: subscribe. */
public final class ConversationTypingEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String conversation;
    private final boolean on;
    private final String participant;

    private ConversationTypingEvent(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public boolean on() { return on; }
    public String participant() { return participant; }
    @Override public String event() { return "conversation-typing"; }

    public static ConversationTypingEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTypingEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-typing", "ConversationTypingEvent.event");
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationTypingEvent.conversation"));
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "ConversationTypingEvent.on"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationTypingEvent.participant"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-typing");
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "on", on);
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTypingEvent that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(on, that.on) && Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, on, participant); }

    @Override
    public String toString() { return "ConversationTypingEvent" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Boolean on;
        private boolean onSet;
        private String participant;
        private boolean participantSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder on(boolean value) {
            this.on = value;
            this.onSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public ConversationTypingEvent build() { return new ConversationTypingEvent(this); }
    }
}

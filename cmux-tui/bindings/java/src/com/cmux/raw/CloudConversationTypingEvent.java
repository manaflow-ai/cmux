// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-typing event. Protocol v12; streams: subscribe. */
public final class CloudConversationTypingEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String conversation;
    private final boolean on;
    private final String participant;

    private CloudConversationTypingEvent(Builder builder) {
        this.account = builder.account;
        this.cause = builder.cause;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public Field<EventCause> cause() { return cause; }
    public String conversation() { return conversation; }
    public boolean on() { return on; }
    public String participant() { return participant; }
    @Override public String event() { return "cloud-conversation-typing"; }

    public static CloudConversationTypingEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationTypingEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-conversation-typing", "CloudConversationTypingEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudConversationTypingEvent.account"));
        }
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationTypingEvent.conversation"));
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "CloudConversationTypingEvent.on"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "CloudConversationTypingEvent.participant"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-conversation-typing");
        Wire.put(object, "account", account);
        Wire.put(object, "cause", cause);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "on", on);
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationTypingEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(cause, that.cause) && Objects.equals(conversation, that.conversation) && Objects.equals(on, that.on) && Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(account, cause, conversation, on, participant); }

    @Override
    public String toString() { return "CloudConversationTypingEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private Field<EventCause> cause = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Boolean on;
        private boolean onSet;
        private String participant;
        private boolean participantSet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
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
        public CloudConversationTypingEvent build() { return new CloudConversationTypingEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-presence event. Protocol v12; streams: subscribe. */
public final class CloudConversationPresenceEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    private final String conversation;
    private final List<CloudConversationPresenceParticipant> participants;

    private CloudConversationPresenceEvent(Builder builder) {
        this.account = builder.account;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.participantsSet) throw new IllegalArgumentException("participants is required");
        this.participants = List.copyOf(Wire.nonNull(builder.participants, "participants"));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public String conversation() { return conversation; }
    public List<CloudConversationPresenceParticipant> participants() { return participants; }
    @Override public String event() { return "cloud-conversation-presence"; }

    public static CloudConversationPresenceEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationPresenceEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-conversation-presence", "CloudConversationPresenceEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudConversationPresenceEvent.account"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationPresenceEvent.conversation"));
        Object rawParticipants = Wire.required(object, "participants");
        builder.participants(Wire.array(rawParticipants, "CloudConversationPresenceEvent.participants", item -> CloudConversationPresenceParticipant.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-conversation-presence");
        Wire.put(object, "account", account);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "participants", participants);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationPresenceEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(conversation, that.conversation) && Objects.equals(participants, that.participants);
    }

    @Override
    public int hashCode() { return Objects.hash(account, conversation, participants); }

    @Override
    public String toString() { return "CloudConversationPresenceEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private List<CloudConversationPresenceParticipant> participants;
        private boolean participantsSet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder participants(List<CloudConversationPresenceParticipant> value) {
            this.participants = value;
            this.participantsSet = true;
            return this;
        }
        public CloudConversationPresenceEvent build() { return new CloudConversationPresenceEvent(this); }
    }
}

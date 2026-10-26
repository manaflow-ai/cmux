// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-inbox-changed event. Protocol v12; streams: subscribe. */
public final class ConversationInboxChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String conversation;
    private final boolean markedUnread;
    private final String participant;
    private final Field<UInt64> pinPosition;
    private final boolean pinned;

    private ConversationInboxChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.markedUnreadSet) throw new IllegalArgumentException("marked_unread is required");
        this.markedUnread = builder.markedUnread;
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        this.pinPosition = builder.pinPosition;
        if (!builder.pinnedSet) throw new IllegalArgumentException("pinned is required");
        this.pinned = builder.pinned;
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public String conversation() { return conversation; }
    public boolean markedUnread() { return markedUnread; }
    public String participant() { return participant; }
    public Field<UInt64> pinPosition() { return pinPosition; }
    public boolean pinned() { return pinned; }
    @Override public String event() { return "conversation-inbox-changed"; }

    public static ConversationInboxChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationInboxChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-inbox-changed", "ConversationInboxChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationInboxChangedEvent.conversation"));
        Object rawMarkedUnread = Wire.required(object, "marked_unread");
        builder.markedUnread(Wire.bool(rawMarkedUnread, "ConversationInboxChangedEvent.marked_unread"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationInboxChangedEvent.participant"));
        Object rawPinPosition = Wire.optional(object, "pin_position");
        if (!Wire.isMissing(rawPinPosition)) {
            builder.pinPosition(Wire.uint64(rawPinPosition, "ConversationInboxChangedEvent.pin_position"));
        }
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "ConversationInboxChangedEvent.pinned"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-inbox-changed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "marked_unread", markedUnread);
        Wire.put(object, "participant", participant);
        Wire.put(object, "pin_position", pinPosition);
        Wire.put(object, "pinned", pinned);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationInboxChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(conversation, that.conversation) && Objects.equals(markedUnread, that.markedUnread) && Objects.equals(participant, that.participant) && Objects.equals(pinPosition, that.pinPosition) && Objects.equals(pinned, that.pinned);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, conversation, markedUnread, participant, pinPosition, pinned); }

    @Override
    public String toString() { return "ConversationInboxChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Boolean markedUnread;
        private boolean markedUnreadSet;
        private String participant;
        private boolean participantSet;
        private Field<UInt64> pinPosition = Field.omitted();
        private Boolean pinned;
        private boolean pinnedSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder markedUnread(boolean value) {
            this.markedUnread = value;
            this.markedUnreadSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder pinPosition(UInt64 value) {
            this.pinPosition = Field.of(value);
            return this;
        }
        public Builder pinned(boolean value) {
            this.pinned = value;
            this.pinnedSet = true;
            return this;
        }
        public ConversationInboxChangedEvent build() { return new ConversationInboxChangedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationInboxOpResult implements WireValue {
    private final String conversation;
    private final boolean markedUnread;
    private final String participant;
    private final Field<UInt64> pinPosition;
    private final boolean pinned;

    private ConversationInboxOpResult(Builder builder) {
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

    public String conversation() { return conversation; }
    public boolean markedUnread() { return markedUnread; }
    public String participant() { return participant; }
    public Field<UInt64> pinPosition() { return pinPosition; }
    public boolean pinned() { return pinned; }

    public static ConversationInboxOpResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationInboxOpResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationInboxOpResult.conversation"));
        Object rawMarkedUnread = Wire.required(object, "marked_unread");
        builder.markedUnread(Wire.bool(rawMarkedUnread, "ConversationInboxOpResult.marked_unread"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationInboxOpResult.participant"));
        Object rawPinPosition = Wire.optional(object, "pin_position");
        if (!Wire.isMissing(rawPinPosition)) {
            builder.pinPosition(Wire.uint64(rawPinPosition, "ConversationInboxOpResult.pin_position"));
        }
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "ConversationInboxOpResult.pinned"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "marked_unread", markedUnread);
        Wire.put(object, "participant", participant);
        Wire.put(object, "pin_position", pinPosition);
        Wire.put(object, "pinned", pinned);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationInboxOpResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(markedUnread, that.markedUnread) && Objects.equals(participant, that.participant) && Objects.equals(pinPosition, that.pinPosition) && Objects.equals(pinned, that.pinned);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, markedUnread, participant, pinPosition, pinned); }

    @Override
    public String toString() { return "ConversationInboxOpResult" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Boolean markedUnread;
        private boolean markedUnreadSet;
        private String participant;
        private boolean participantSet;
        private Field<UInt64> pinPosition = Field.omitted();
        private Boolean pinned;
        private boolean pinnedSet;

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
        public ConversationInboxOpResult build() { return new ConversationInboxOpResult(this); }
    }
}

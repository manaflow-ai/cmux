// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-live event. Protocol v12; streams: subscribe. */
public final class ConversationLiveEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String conversation;
    private final Object frame;

    private ConversationLiveEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.frameSet) throw new IllegalArgumentException("frame is required");
        this.frame = builder.frame == null ? null : Wire.immutableJson(builder.frame);
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public String conversation() { return conversation; }
    public Object frame() { return frame; }
    @Override public String event() { return "conversation-live"; }

    public static ConversationLiveEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationLiveEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-live", "ConversationLiveEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationLiveEvent.conversation"));
        Object rawFrame = Wire.required(object, "frame");
        builder.frame(rawFrame == null ? null : Wire.immutableJson(rawFrame));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-live");
        Wire.put(object, "cause", cause);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "frame", frame);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationLiveEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(conversation, that.conversation) && Objects.equals(frame, that.frame);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, conversation, frame); }

    @Override
    public String toString() { return "ConversationLiveEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Object frame;
        private boolean frameSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder frame(Object value) {
            this.frame = value;
            this.frameSet = true;
            return this;
        }
        public ConversationLiveEvent build() { return new ConversationLiveEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-live event. Protocol v12; streams: subscribe. */
public final class CloudConversationLiveEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String conversation;
    private final Object frame;

    private CloudConversationLiveEvent(Builder builder) {
        this.account = builder.account;
        this.cause = builder.cause;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.frameSet) throw new IllegalArgumentException("frame is required");
        this.frame = builder.frame == null ? null : Wire.immutableJson(builder.frame);
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public Field<EventCause> cause() { return cause; }
    public String conversation() { return conversation; }
    public Object frame() { return frame; }
    @Override public String event() { return "cloud-conversation-live"; }

    public static CloudConversationLiveEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationLiveEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-conversation-live", "CloudConversationLiveEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudConversationLiveEvent.account"));
        }
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationLiveEvent.conversation"));
        Object rawFrame = Wire.required(object, "frame");
        builder.frame(rawFrame == null ? null : Wire.immutableJson(rawFrame));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-conversation-live");
        Wire.put(object, "account", account);
        Wire.put(object, "cause", cause);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "frame", frame);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationLiveEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(cause, that.cause) && Objects.equals(conversation, that.conversation) && Objects.equals(frame, that.frame);
    }

    @Override
    public int hashCode() { return Objects.hash(account, cause, conversation, frame); }

    @Override
    public String toString() { return "CloudConversationLiveEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private Field<EventCause> cause = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Object frame;
        private boolean frameSet;

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
        public Builder frame(Object value) {
            this.frame = value;
            this.frameSet = true;
            return this;
        }
        public CloudConversationLiveEvent build() { return new CloudConversationLiveEvent(this); }
    }
}

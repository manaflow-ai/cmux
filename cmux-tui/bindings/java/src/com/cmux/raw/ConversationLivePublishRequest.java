// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-live-publish request. Protocol v12; authority: local-admin. */
public final class ConversationLivePublishRequest implements WireValue {
    private final String conversation;
    private final Object frame;

    private ConversationLivePublishRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.frameSet) throw new IllegalArgumentException("frame is required");
        this.frame = builder.frame == null ? null : Wire.immutableJson(builder.frame);
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public Object frame() { return frame; }

    public static ConversationLivePublishRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationLivePublishRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationLivePublishRequest.conversation"));
        Object rawFrame = Wire.required(object, "frame");
        builder.frame(rawFrame == null ? null : Wire.immutableJson(rawFrame));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "frame", frame);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationLivePublishRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(frame, that.frame);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, frame); }

    @Override
    public String toString() { return "ConversationLivePublishRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Object frame;
        private boolean frameSet;

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
        public ConversationLivePublishRequest build() { return new ConversationLivePublishRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-typing request. Protocol v12; authority: local-admin. */
public final class CloudConversationTypingRequest implements WireValue {
    private final String conversation;
    private final boolean on;

    private CloudConversationTypingRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public boolean on() { return on; }

    public static CloudConversationTypingRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationTypingRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationTypingRequest.conversation"));
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "CloudConversationTypingRequest.on"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "on", on);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationTypingRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(on, that.on);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, on); }

    @Override
    public String toString() { return "CloudConversationTypingRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Boolean on;
        private boolean onSet;

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
        public CloudConversationTypingRequest build() { return new CloudConversationTypingRequest(this); }
    }
}

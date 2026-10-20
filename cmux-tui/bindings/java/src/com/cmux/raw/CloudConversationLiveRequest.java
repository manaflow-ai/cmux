// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-live request. Protocol v12; authority: local-admin. */
public final class CloudConversationLiveRequest implements WireValue {
    private final String conversation;

    private CloudConversationLiveRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }

    public static CloudConversationLiveRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationLiveRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationLiveRequest.conversation"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationLiveRequest that)) return false;
        return Objects.equals(conversation, that.conversation);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation); }

    @Override
    public String toString() { return "CloudConversationLiveRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public CloudConversationLiveRequest build() { return new CloudConversationLiveRequest(this); }
    }
}

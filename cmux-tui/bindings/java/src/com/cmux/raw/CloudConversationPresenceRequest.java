// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-conversation-presence request. Protocol v12; authority: local-admin. */
public final class CloudConversationPresenceRequest implements WireValue {
    private final String conversation;
    private final boolean viewing;

    private CloudConversationPresenceRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.viewingSet) throw new IllegalArgumentException("viewing is required");
        this.viewing = builder.viewing;
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public boolean viewing() { return viewing; }

    public static CloudConversationPresenceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationPresenceRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudConversationPresenceRequest.conversation"));
        Object rawViewing = Wire.required(object, "viewing");
        builder.viewing(Wire.bool(rawViewing, "CloudConversationPresenceRequest.viewing"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "viewing", viewing);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationPresenceRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(viewing, that.viewing);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, viewing); }

    @Override
    public String toString() { return "CloudConversationPresenceRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Boolean viewing;
        private boolean viewingSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder viewing(boolean value) {
            this.viewing = value;
            this.viewingSet = true;
            return this;
        }
        public CloudConversationPresenceRequest build() { return new CloudConversationPresenceRequest(this); }
    }
}

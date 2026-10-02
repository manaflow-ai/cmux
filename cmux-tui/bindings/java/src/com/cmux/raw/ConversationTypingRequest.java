// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-typing request. Protocol v12; authority: local-admin. */
public final class ConversationTypingRequest implements WireValue {
    private final Field<String> actor;
    private final String conversation;
    private final boolean on;

    private ConversationTypingRequest(Builder builder) {
        this.actor = builder.actor;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> actor() { return actor; }
    public String conversation() { return conversation; }
    public boolean on() { return on; }

    public static ConversationTypingRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTypingRequest");
        Builder builder = builder();
        Object rawActor = Wire.optional(object, "actor");
        if (!Wire.isMissing(rawActor)) {
            builder.actor(rawActor == null ? null : Wire.string(rawActor, "ConversationTypingRequest.actor"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationTypingRequest.conversation"));
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "ConversationTypingRequest.on"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "actor", actor);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "on", on);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTypingRequest that)) return false;
        return Objects.equals(actor, that.actor) && Objects.equals(conversation, that.conversation) && Objects.equals(on, that.on);
    }

    @Override
    public int hashCode() { return Objects.hash(actor, conversation, on); }

    @Override
    public String toString() { return "ConversationTypingRequest" + toWire(); }

    public static final class Builder {
        private Field<String> actor = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Boolean on;
        private boolean onSet;

        public Builder actor(String value) {
            this.actor = Field.ofNullable(value);
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
        public ConversationTypingRequest build() { return new ConversationTypingRequest(this); }
    }
}

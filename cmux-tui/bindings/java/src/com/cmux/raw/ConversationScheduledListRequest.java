// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-scheduled-list request. Protocol v12; authority: local-admin. */
public final class ConversationScheduledListRequest implements WireValue {
    private final Field<String> conversation;

    private ConversationScheduledListRequest(Builder builder) {
        this.conversation = builder.conversation;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> conversation() { return conversation; }

    public static ConversationScheduledListRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationScheduledListRequest");
        Builder builder = builder();
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : Wire.string(rawConversation, "ConversationScheduledListRequest.conversation"));
        }
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
        if (!(other instanceof ConversationScheduledListRequest that)) return false;
        return Objects.equals(conversation, that.conversation);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation); }

    @Override
    public String toString() { return "ConversationScheduledListRequest" + toWire(); }

    public static final class Builder {
        private Field<String> conversation = Field.omitted();

        public Builder conversation(String value) {
            this.conversation = Field.ofNullable(value);
            return this;
        }
        public ConversationScheduledListRequest build() { return new ConversationScheduledListRequest(this); }
    }
}

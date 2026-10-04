// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationListResult implements WireValue {
    private final List<ConversationSummary> conversations;

    private ConversationListResult(Builder builder) {
        if (!builder.conversationsSet) throw new IllegalArgumentException("conversations is required");
        this.conversations = List.copyOf(Wire.nonNull(builder.conversations, "conversations"));
    }

    public static Builder builder() { return new Builder(); }

    public List<ConversationSummary> conversations() { return conversations; }

    public static ConversationListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationListResult");
        Builder builder = builder();
        Object rawConversations = Wire.required(object, "conversations");
        builder.conversations(Wire.array(rawConversations, "ConversationListResult.conversations", item -> ConversationSummary.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversations", conversations);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationListResult that)) return false;
        return Objects.equals(conversations, that.conversations);
    }

    @Override
    public int hashCode() { return Objects.hash(conversations); }

    @Override
    public String toString() { return "ConversationListResult" + toWire(); }

    public static final class Builder {
        private List<ConversationSummary> conversations;
        private boolean conversationsSet;

        public Builder conversations(List<ConversationSummary> value) {
            this.conversations = value;
            this.conversationsSet = true;
            return this;
        }
        public ConversationListResult build() { return new ConversationListResult(this); }
    }
}

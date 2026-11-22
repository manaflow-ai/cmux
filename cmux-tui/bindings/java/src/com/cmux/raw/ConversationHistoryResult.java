// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationHistoryResult implements WireValue {
    private final List<ConversationMessage> messages;

    private ConversationHistoryResult(Builder builder) {
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = List.copyOf(Wire.nonNull(builder.messages, "messages"));
    }

    public static Builder builder() { return new Builder(); }

    public List<ConversationMessage> messages() { return messages; }

    public static ConversationHistoryResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationHistoryResult");
        Builder builder = builder();
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.array(rawMessages, "ConversationHistoryResult.messages", item -> ConversationMessage.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "messages", messages);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationHistoryResult that)) return false;
        return Objects.equals(messages, that.messages);
    }

    @Override
    public int hashCode() { return Objects.hash(messages); }

    @Override
    public String toString() { return "ConversationHistoryResult" + toWire(); }

    public static final class Builder {
        private List<ConversationMessage> messages;
        private boolean messagesSet;

        public Builder messages(List<ConversationMessage> value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public ConversationHistoryResult build() { return new ConversationHistoryResult(this); }
    }
}

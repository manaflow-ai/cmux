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
    private final Field<List<ConversationThreadSummary>> threads;

    private ConversationHistoryResult(Builder builder) {
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = List.copyOf(Wire.nonNull(builder.messages, "messages"));
        this.threads = builder.threads.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public List<ConversationMessage> messages() { return messages; }
    public Field<List<ConversationThreadSummary>> threads() { return threads; }

    public static ConversationHistoryResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationHistoryResult");
        Builder builder = builder();
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.array(rawMessages, "ConversationHistoryResult.messages", item -> ConversationMessage.fromWire(item)));
        Object rawThreads = Wire.optional(object, "threads");
        if (!Wire.isMissing(rawThreads)) {
            builder.threads(Wire.array(rawThreads, "ConversationHistoryResult.threads", item -> ConversationThreadSummary.fromWire(item)));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "messages", messages);
        Wire.put(object, "threads", threads);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationHistoryResult that)) return false;
        return Objects.equals(messages, that.messages) && Objects.equals(threads, that.threads);
    }

    @Override
    public int hashCode() { return Objects.hash(messages, threads); }

    @Override
    public String toString() { return "ConversationHistoryResult" + toWire(); }

    public static final class Builder {
        private List<ConversationMessage> messages;
        private boolean messagesSet;
        private Field<List<ConversationThreadSummary>> threads = Field.omitted();

        public Builder messages(List<ConversationMessage> value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public Builder threads(List<ConversationThreadSummary> value) {
            this.threads = Field.of(value);
            return this;
        }
        public ConversationHistoryResult build() { return new ConversationHistoryResult(this); }
    }
}

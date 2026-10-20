// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationLiveResult implements WireValue {
    private final String conversation;
    private final List<Object> runs;

    private ConversationLiveResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.runsSet) throw new IllegalArgumentException("runs is required");
        this.runs = List.copyOf(Wire.nonNull(builder.runs, "runs"));
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public List<Object> runs() { return runs; }
    public String type() { return "run.live"; }

    public static ConversationLiveResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationLiveResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationLiveResult.conversation"));
        Object rawRuns = Wire.required(object, "runs");
        builder.runs(Wire.array(rawRuns, "ConversationLiveResult.runs", item -> Wire.immutableJson(item)));
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "run.live", "ConversationLiveResult.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "runs", runs);
        Wire.put(object, "type", "run.live");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationLiveResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(runs, that.runs);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, runs); }

    @Override
    public String toString() { return "ConversationLiveResult" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private List<Object> runs;
        private boolean runsSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder runs(List<Object> value) {
            this.runs = value;
            this.runsSet = true;
            return this;
        }
        public ConversationLiveResult build() { return new ConversationLiveResult(this); }
    }
}

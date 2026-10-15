// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-run-append request. Protocol v12; authority: local-admin. */
public final class ConversationRunAppendRequest implements WireValue {
    private final String conversation;
    private final Object run;
    private final Field<List<Object>> steps;

    private ConversationRunAppendRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = builder.run == null ? null : Wire.immutableJson(builder.run);
        this.steps = builder.steps.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public Object run() { return run; }
    public Field<List<Object>> steps() { return steps; }

    public static ConversationRunAppendRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationRunAppendRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationRunAppendRequest.conversation"));
        Object rawRun = Wire.required(object, "run");
        builder.run(rawRun == null ? null : Wire.immutableJson(rawRun));
        Object rawSteps = Wire.optional(object, "steps");
        if (!Wire.isMissing(rawSteps)) {
            builder.steps(Wire.array(rawSteps, "ConversationRunAppendRequest.steps", item -> Wire.immutableJson(item)));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "run", run);
        Wire.put(object, "steps", steps);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationRunAppendRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(run, that.run) && Objects.equals(steps, that.steps);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, run, steps); }

    @Override
    public String toString() { return "ConversationRunAppendRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Object run;
        private boolean runSet;
        private Field<List<Object>> steps = Field.omitted();

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder run(Object value) {
            this.run = value;
            this.runSet = true;
            return this;
        }
        public Builder steps(List<Object> value) {
            this.steps = Field.of(value);
            return this;
        }
        public ConversationRunAppendRequest build() { return new ConversationRunAppendRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-run-changed event. Protocol v12; streams: subscribe. */
public final class ConversationRunChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String conversation;
    private final Object run;
    private final List<Object> steps;

    private ConversationRunChangedEvent(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = builder.run == null ? null : Wire.immutableJson(builder.run);
        if (!builder.stepsSet) throw new IllegalArgumentException("steps is required");
        this.steps = List.copyOf(Wire.nonNull(builder.steps, "steps"));
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public Object run() { return run; }
    public List<Object> steps() { return steps; }
    @Override public String event() { return "conversation-run-changed"; }

    public static ConversationRunChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationRunChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "conversation-run-changed", "ConversationRunChangedEvent.event");
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationRunChangedEvent.conversation"));
        Object rawRun = Wire.required(object, "run");
        builder.run(rawRun == null ? null : Wire.immutableJson(rawRun));
        Object rawSteps = Wire.required(object, "steps");
        builder.steps(Wire.array(rawSteps, "ConversationRunChangedEvent.steps", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "conversation-run-changed");
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "run", run);
        Wire.put(object, "steps", steps);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationRunChangedEvent that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(run, that.run) && Objects.equals(steps, that.steps);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, run, steps); }

    @Override
    public String toString() { return "ConversationRunChangedEvent" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Object run;
        private boolean runSet;
        private List<Object> steps;
        private boolean stepsSet;

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
            this.steps = value;
            this.stepsSet = true;
            return this;
        }
        public ConversationRunChangedEvent build() { return new ConversationRunChangedEvent(this); }
    }
}

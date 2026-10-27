// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentCliIntentsListResult implements WireValue {
    private final List<AgentCLIStoredIntent> intents;

    private AgentCliIntentsListResult(Builder builder) {
        if (!builder.intentsSet) throw new IllegalArgumentException("intents is required");
        this.intents = List.copyOf(Wire.nonNull(builder.intents, "intents"));
    }

    public static Builder builder() { return new Builder(); }

    public List<AgentCLIStoredIntent> intents() { return intents; }

    public static AgentCliIntentsListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsListResult");
        Builder builder = builder();
        Object rawIntents = Wire.required(object, "intents");
        builder.intents(Wire.array(rawIntents, "AgentCliIntentsListResult.intents", item -> AgentCLIStoredIntent.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "intents", intents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsListResult that)) return false;
        return Objects.equals(intents, that.intents);
    }

    @Override
    public int hashCode() { return Objects.hash(intents); }

    @Override
    public String toString() { return "AgentCliIntentsListResult" + toWire(); }

    public static final class Builder {
        private List<AgentCLIStoredIntent> intents;
        private boolean intentsSet;

        public Builder intents(List<AgentCLIStoredIntent> value) {
            this.intents = value;
            this.intentsSet = true;
            return this;
        }
        public AgentCliIntentsListResult build() { return new AgentCliIntentsListResult(this); }
    }
}

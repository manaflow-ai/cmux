// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListAgentsResult implements WireValue {
    private final List<AgentRecord> agents;

    private ListAgentsResult(Builder builder) {
        if (!builder.agentsSet) throw new IllegalArgumentException("agents is required");
        this.agents = List.copyOf(Wire.nonNull(builder.agents, "agents"));
    }

    public static Builder builder() { return new Builder(); }

    public List<AgentRecord> agents() { return agents; }

    public static ListAgentsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListAgentsResult");
        Builder builder = builder();
        Object rawAgents = Wire.required(object, "agents");
        builder.agents(Wire.array(rawAgents, "ListAgentsResult.agents", item -> AgentRecord.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agents", agents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListAgentsResult that)) return false;
        return Objects.equals(agents, that.agents);
    }

    @Override
    public int hashCode() { return Objects.hash(agents); }

    @Override
    public String toString() { return "ListAgentsResult" + toWire(); }

    public static final class Builder {
        private List<AgentRecord> agents;
        private boolean agentsSet;

        public Builder agents(List<AgentRecord> value) {
            this.agents = value;
            this.agentsSet = true;
            return this;
        }
        public ListAgentsResult build() { return new ListAgentsResult(this); }
    }
}

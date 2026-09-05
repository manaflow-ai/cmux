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
    /** True when this session has committed at least one agent projection, including a completed lifecycle. Present only when the client negotiates agent-history-v1. */
    private final Field<Boolean> hasHistory;
    /** Durable lifecycle projections retained for explicit state-filtered views. Present only when the client negotiates agent-history-v1; absent from older protocol-12 clients. */
    private final Field<List<AgentRecord>> history;

    private ListAgentsResult(Builder builder) {
        if (!builder.agentsSet) throw new IllegalArgumentException("agents is required");
        this.agents = List.copyOf(Wire.nonNull(builder.agents, "agents"));
        this.hasHistory = builder.hasHistory;
        this.history = builder.history.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public List<AgentRecord> agents() { return agents; }
    public Field<Boolean> hasHistory() { return hasHistory; }
    public Field<List<AgentRecord>> history() { return history; }

    public static ListAgentsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListAgentsResult");
        Builder builder = builder();
        Object rawAgents = Wire.required(object, "agents");
        builder.agents(Wire.array(rawAgents, "ListAgentsResult.agents", item -> AgentRecord.fromWire(item)));
        Object rawHasHistory = Wire.optional(object, "has_history");
        if (!Wire.isMissing(rawHasHistory)) {
            builder.hasHistory(Wire.bool(rawHasHistory, "ListAgentsResult.has_history"));
        }
        Object rawHistory = Wire.optional(object, "history");
        if (!Wire.isMissing(rawHistory)) {
            builder.history(Wire.array(rawHistory, "ListAgentsResult.history", item -> AgentRecord.fromWire(item)));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agents", agents);
        Wire.put(object, "has_history", hasHistory);
        Wire.put(object, "history", history);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListAgentsResult that)) return false;
        return Objects.equals(agents, that.agents) && Objects.equals(hasHistory, that.hasHistory) && Objects.equals(history, that.history);
    }

    @Override
    public int hashCode() { return Objects.hash(agents, hasHistory, history); }

    @Override
    public String toString() { return "ListAgentsResult" + toWire(); }

    public static final class Builder {
        private List<AgentRecord> agents;
        private boolean agentsSet;
        private Field<Boolean> hasHistory = Field.omitted();
        private Field<List<AgentRecord>> history = Field.omitted();

        public Builder agents(List<AgentRecord> value) {
            this.agents = value;
            this.agentsSet = true;
            return this;
        }
        public Builder hasHistory(Boolean value) {
            this.hasHistory = Field.of(value);
            return this;
        }
        public Builder history(List<AgentRecord> value) {
            this.history = Field.of(value);
            return this;
        }
        public ListAgentsResult build() { return new ListAgentsResult(this); }
    }
}

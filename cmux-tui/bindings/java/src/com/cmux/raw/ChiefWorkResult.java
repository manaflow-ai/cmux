// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ChiefWorkResult implements WireValue {
    private final List<ChiefWorkAgent> agents;
    private final List<String> taskSources;
    private final List<ChiefWorkTask> tasks;
    private final boolean truncated;

    private ChiefWorkResult(Builder builder) {
        if (!builder.agentsSet) throw new IllegalArgumentException("agents is required");
        this.agents = List.copyOf(Wire.nonNull(builder.agents, "agents"));
        if (!builder.taskSourcesSet) throw new IllegalArgumentException("taskSources is required");
        this.taskSources = List.copyOf(Wire.nonNull(builder.taskSources, "taskSources"));
        if (!builder.tasksSet) throw new IllegalArgumentException("tasks is required");
        this.tasks = List.copyOf(Wire.nonNull(builder.tasks, "tasks"));
        if (!builder.truncatedSet) throw new IllegalArgumentException("truncated is required");
        this.truncated = builder.truncated;
    }

    public static Builder builder() { return new Builder(); }

    public List<ChiefWorkAgent> agents() { return agents; }
    public List<String> taskSources() { return taskSources; }
    public List<ChiefWorkTask> tasks() { return tasks; }
    public boolean truncated() { return truncated; }

    public static ChiefWorkResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefWorkResult");
        Builder builder = builder();
        Object rawAgents = Wire.required(object, "agents");
        builder.agents(Wire.array(rawAgents, "ChiefWorkResult.agents", item -> ChiefWorkAgent.fromWire(item)));
        Object rawTaskSources = Wire.required(object, "taskSources");
        builder.taskSources(Wire.array(rawTaskSources, "ChiefWorkResult.taskSources", item -> Wire.string(item, "ChiefWorkResult.taskSources item")));
        Object rawTasks = Wire.required(object, "tasks");
        builder.tasks(Wire.array(rawTasks, "ChiefWorkResult.tasks", item -> ChiefWorkTask.fromWire(item)));
        Object rawTruncated = Wire.required(object, "truncated");
        builder.truncated(Wire.bool(rawTruncated, "ChiefWorkResult.truncated"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agents", agents);
        Wire.put(object, "taskSources", taskSources);
        Wire.put(object, "tasks", tasks);
        Wire.put(object, "truncated", truncated);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefWorkResult that)) return false;
        return Objects.equals(agents, that.agents) && Objects.equals(taskSources, that.taskSources) && Objects.equals(tasks, that.tasks) && Objects.equals(truncated, that.truncated);
    }

    @Override
    public int hashCode() { return Objects.hash(agents, taskSources, tasks, truncated); }

    @Override
    public String toString() { return "ChiefWorkResult" + toWire(); }

    public static final class Builder {
        private List<ChiefWorkAgent> agents;
        private boolean agentsSet;
        private List<String> taskSources;
        private boolean taskSourcesSet;
        private List<ChiefWorkTask> tasks;
        private boolean tasksSet;
        private Boolean truncated;
        private boolean truncatedSet;

        public Builder agents(List<ChiefWorkAgent> value) {
            this.agents = value;
            this.agentsSet = true;
            return this;
        }
        public Builder taskSources(List<String> value) {
            this.taskSources = value;
            this.taskSourcesSet = true;
            return this;
        }
        public Builder tasks(List<ChiefWorkTask> value) {
            this.tasks = value;
            this.tasksSet = true;
            return this;
        }
        public Builder truncated(boolean value) {
            this.truncated = value;
            this.truncatedSet = true;
            return this;
        }
        public ChiefWorkResult build() { return new ChiefWorkResult(this); }
    }
}

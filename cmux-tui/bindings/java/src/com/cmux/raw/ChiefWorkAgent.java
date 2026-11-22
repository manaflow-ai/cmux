// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ChiefWorkAgent implements WireValue {
    private final String id;
    private final String name;
    private final UInt64 startedAt;
    private final ChiefWorkAgentState state;
    private final String task;
    private final UInt64 updatedAt;

    private ChiefWorkAgent(Builder builder) {
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.startedAtSet) throw new IllegalArgumentException("startedAt is required");
        this.startedAt = builder.startedAt;
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
        if (!builder.taskSet) throw new IllegalArgumentException("task is required");
        this.task = builder.task;
        if (!builder.updatedAtSet) throw new IllegalArgumentException("updatedAt is required");
        this.updatedAt = builder.updatedAt;
    }

    public static Builder builder() { return new Builder(); }

    public String id() { return id; }
    public String name() { return name; }
    public UInt64 startedAt() { return startedAt; }
    public ChiefWorkAgentState state() { return state; }
    public String task() { return task; }
    public UInt64 updatedAt() { return updatedAt; }

    public static ChiefWorkAgent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefWorkAgent");
        Builder builder = builder();
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "ChiefWorkAgent.id"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "ChiefWorkAgent.name"));
        Object rawStartedAt = Wire.required(object, "startedAt");
        builder.startedAt(rawStartedAt == null ? null : Wire.uint64(rawStartedAt, "ChiefWorkAgent.startedAt"));
        Object rawState = Wire.required(object, "state");
        builder.state(ChiefWorkAgentState.fromWire(rawState));
        Object rawTask = Wire.required(object, "task");
        builder.task(rawTask == null ? null : Wire.string(rawTask, "ChiefWorkAgent.task"));
        Object rawUpdatedAt = Wire.required(object, "updatedAt");
        builder.updatedAt(rawUpdatedAt == null ? null : Wire.uint64(rawUpdatedAt, "ChiefWorkAgent.updatedAt"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "id", id);
        Wire.put(object, "name", name);
        Wire.put(object, "startedAt", startedAt);
        Wire.put(object, "state", state);
        Wire.put(object, "task", task);
        Wire.put(object, "updatedAt", updatedAt);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefWorkAgent that)) return false;
        return Objects.equals(id, that.id) && Objects.equals(name, that.name) && Objects.equals(startedAt, that.startedAt) && Objects.equals(state, that.state) && Objects.equals(task, that.task) && Objects.equals(updatedAt, that.updatedAt);
    }

    @Override
    public int hashCode() { return Objects.hash(id, name, startedAt, state, task, updatedAt); }

    @Override
    public String toString() { return "ChiefWorkAgent" + toWire(); }

    public static final class Builder {
        private String id;
        private boolean idSet;
        private String name;
        private boolean nameSet;
        private UInt64 startedAt;
        private boolean startedAtSet;
        private ChiefWorkAgentState state;
        private boolean stateSet;
        private String task;
        private boolean taskSet;
        private UInt64 updatedAt;
        private boolean updatedAtSet;

        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder startedAt(UInt64 value) {
            this.startedAt = value;
            this.startedAtSet = true;
            return this;
        }
        public Builder state(ChiefWorkAgentState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public Builder task(String value) {
            this.task = value;
            this.taskSet = true;
            return this;
        }
        public Builder updatedAt(UInt64 value) {
            this.updatedAt = value;
            this.updatedAtSet = true;
            return this;
        }
        public ChiefWorkAgent build() { return new ChiefWorkAgent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentUpdatePlanResult implements WireValue {
    private final List<AgentUpdateHarness> harnesses;
    private final UInt64 liveThreads;
    private final Field<String> machine;
    private final UInt64 runningThreads;

    private AgentUpdatePlanResult(Builder builder) {
        if (!builder.harnessesSet) throw new IllegalArgumentException("harnesses is required");
        this.harnesses = List.copyOf(Wire.nonNull(builder.harnesses, "harnesses"));
        if (!builder.liveThreadsSet) throw new IllegalArgumentException("live_threads is required");
        this.liveThreads = Wire.nonNull(builder.liveThreads, "live_threads");
        this.machine = builder.machine;
        if (!builder.runningThreadsSet) throw new IllegalArgumentException("running_threads is required");
        this.runningThreads = Wire.nonNull(builder.runningThreads, "running_threads");
    }

    public static Builder builder() { return new Builder(); }

    public List<AgentUpdateHarness> harnesses() { return harnesses; }
    public UInt64 liveThreads() { return liveThreads; }
    public Field<String> machine() { return machine; }
    public UInt64 runningThreads() { return runningThreads; }

    public static AgentUpdatePlanResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentUpdatePlanResult");
        Builder builder = builder();
        Object rawHarnesses = Wire.required(object, "harnesses");
        builder.harnesses(Wire.array(rawHarnesses, "AgentUpdatePlanResult.harnesses", item -> AgentUpdateHarness.fromWire(item)));
        Object rawLiveThreads = Wire.required(object, "live_threads");
        builder.liveThreads(Wire.uint64(rawLiveThreads, "AgentUpdatePlanResult.live_threads"));
        Object rawMachine = Wire.optional(object, "machine");
        if (!Wire.isMissing(rawMachine)) {
            builder.machine(Wire.string(rawMachine, "AgentUpdatePlanResult.machine"));
        }
        Object rawRunningThreads = Wire.required(object, "running_threads");
        builder.runningThreads(Wire.uint64(rawRunningThreads, "AgentUpdatePlanResult.running_threads"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "harnesses", harnesses);
        Wire.put(object, "live_threads", liveThreads);
        Wire.put(object, "machine", machine);
        Wire.put(object, "running_threads", runningThreads);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentUpdatePlanResult that)) return false;
        return Objects.equals(harnesses, that.harnesses) && Objects.equals(liveThreads, that.liveThreads) && Objects.equals(machine, that.machine) && Objects.equals(runningThreads, that.runningThreads);
    }

    @Override
    public int hashCode() { return Objects.hash(harnesses, liveThreads, machine, runningThreads); }

    @Override
    public String toString() { return "AgentUpdatePlanResult" + toWire(); }

    public static final class Builder {
        private List<AgentUpdateHarness> harnesses;
        private boolean harnessesSet;
        private UInt64 liveThreads;
        private boolean liveThreadsSet;
        private Field<String> machine = Field.omitted();
        private UInt64 runningThreads;
        private boolean runningThreadsSet;

        public Builder harnesses(List<AgentUpdateHarness> value) {
            this.harnesses = value;
            this.harnessesSet = true;
            return this;
        }
        public Builder liveThreads(UInt64 value) {
            this.liveThreads = value;
            this.liveThreadsSet = true;
            return this;
        }
        public Builder machine(String value) {
            this.machine = Field.of(value);
            return this;
        }
        public Builder runningThreads(UInt64 value) {
            this.runningThreads = value;
            this.runningThreadsSet = true;
            return this;
        }
        public AgentUpdatePlanResult build() { return new AgentUpdatePlanResult(this); }
    }
}

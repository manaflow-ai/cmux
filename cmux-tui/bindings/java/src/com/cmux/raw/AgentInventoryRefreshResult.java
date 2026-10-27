// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentInventoryRefreshResult implements WireValue {
    private final List<AgentInventoryHarness> harnesses;
    /** Canonical public machine id (`machine_…`) of the daemon that answered. */
    private final String machine;

    private AgentInventoryRefreshResult(Builder builder) {
        if (!builder.harnessesSet) throw new IllegalArgumentException("harnesses is required");
        this.harnesses = List.copyOf(Wire.nonNull(builder.harnesses, "harnesses"));
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
    }

    public static Builder builder() { return new Builder(); }

    public Boolean cached() { return true; }
    public List<AgentInventoryHarness> harnesses() { return harnesses; }
    public String machine() { return machine; }
    public String view() { return "inventory"; }

    public static AgentInventoryRefreshResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryRefreshResult");
        Builder builder = builder();
        Object rawCached = Wire.required(object, "cached");
        ProtocolSupport.literal(rawCached, true, "AgentInventoryRefreshResult.cached");
        Object rawHarnesses = Wire.required(object, "harnesses");
        builder.harnesses(Wire.array(rawHarnesses, "AgentInventoryRefreshResult.harnesses", item -> AgentInventoryHarness.fromWire(item)));
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentInventoryRefreshResult.machine"));
        Object rawView = Wire.required(object, "view");
        ProtocolSupport.literal(rawView, "inventory", "AgentInventoryRefreshResult.view");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cached", true);
        Wire.put(object, "harnesses", harnesses);
        Wire.put(object, "machine", machine);
        Wire.put(object, "view", "inventory");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryRefreshResult that)) return false;
        return Objects.equals(harnesses, that.harnesses) && Objects.equals(machine, that.machine);
    }

    @Override
    public int hashCode() { return Objects.hash(harnesses, machine); }

    @Override
    public String toString() { return "AgentInventoryRefreshResult" + toWire(); }

    public static final class Builder {
        private List<AgentInventoryHarness> harnesses;
        private boolean harnessesSet;
        private String machine;
        private boolean machineSet;

        public Builder harnesses(List<AgentInventoryHarness> value) {
            this.harnesses = value;
            this.harnessesSet = true;
            return this;
        }
        public Builder machine(String value) {
            this.machine = value;
            this.machineSet = true;
            return this;
        }
        public AgentInventoryRefreshResult build() { return new AgentInventoryRefreshResult(this); }
    }
}

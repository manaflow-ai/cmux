// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentInventoryResult implements WireValue {
    private final List<AgentInventoryHarness> harnesses;

    private AgentInventoryResult(Builder builder) {
        if (!builder.harnessesSet) throw new IllegalArgumentException("harnesses is required");
        this.harnesses = List.copyOf(Wire.nonNull(builder.harnesses, "harnesses"));
    }

    public static Builder builder() { return new Builder(); }

    public Boolean cached() { return true; }
    public List<AgentInventoryHarness> harnesses() { return harnesses; }
    public String view() { return "inventory"; }

    public static AgentInventoryResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryResult");
        Builder builder = builder();
        Object rawCached = Wire.required(object, "cached");
        ProtocolSupport.literal(rawCached, true, "AgentInventoryResult.cached");
        Object rawHarnesses = Wire.required(object, "harnesses");
        builder.harnesses(Wire.array(rawHarnesses, "AgentInventoryResult.harnesses", item -> AgentInventoryHarness.fromWire(item)));
        Object rawView = Wire.required(object, "view");
        ProtocolSupport.literal(rawView, "inventory", "AgentInventoryResult.view");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cached", true);
        Wire.put(object, "harnesses", harnesses);
        Wire.put(object, "view", "inventory");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryResult that)) return false;
        return Objects.equals(harnesses, that.harnesses);
    }

    @Override
    public int hashCode() { return Objects.hash(harnesses); }

    @Override
    public String toString() { return "AgentInventoryResult" + toWire(); }

    public static final class Builder {
        private List<AgentInventoryHarness> harnesses;
        private boolean harnessesSet;

        public Builder harnesses(List<AgentInventoryHarness> value) {
            this.harnesses = value;
            this.harnessesSet = true;
            return this;
        }
        public AgentInventoryResult build() { return new AgentInventoryResult(this); }
    }
}

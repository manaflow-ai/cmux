// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-inventory-refresh request. Protocol v12; authority: local-admin. */
public final class AgentInventoryRefreshRequest implements WireValue {
    /** Identity fence: the canonical public machine id the caller expects; another daemon refuses with agent_inventory.owner_mismatch. Never a routing selector. */
    private final String expectedMachineId;

    private AgentInventoryRefreshRequest(Builder builder) {
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
    }

    public static Builder builder() { return new Builder(); }

    public String expectedMachineId() { return expectedMachineId; }

    public static AgentInventoryRefreshRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryRefreshRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentInventoryRefreshRequest.expected_machine_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_machine_id", expectedMachineId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryRefreshRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId); }

    @Override
    public String toString() { return "AgentInventoryRefreshRequest" + toWire(); }

    public static final class Builder {
        private String expectedMachineId;
        private boolean expectedMachineIdSet;

        public Builder expectedMachineId(String value) {
            this.expectedMachineId = value;
            this.expectedMachineIdSet = true;
            return this;
        }
        public AgentInventoryRefreshRequest build() { return new AgentInventoryRefreshRequest(this); }
    }
}

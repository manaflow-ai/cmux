// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-inventory request. Protocol v12; authority: local-admin. */
public final class AgentInventoryRequest implements WireValue {
    /** Identity fence: the canonical public machine id the caller expects; another daemon refuses with agent_inventory.owner_mismatch. Never a routing selector. */
    private final Field<String> expectedMachineId;

    private AgentInventoryRequest(Builder builder) {
        this.expectedMachineId = builder.expectedMachineId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> expectedMachineId() { return expectedMachineId; }

    public static AgentInventoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.optional(object, "expected_machine_id");
        if (!Wire.isMissing(rawExpectedMachineId)) {
            builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentInventoryRequest.expected_machine_id"));
        }
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
        if (!(other instanceof AgentInventoryRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId); }

    @Override
    public String toString() { return "AgentInventoryRequest" + toWire(); }

    public static final class Builder {
        private Field<String> expectedMachineId = Field.omitted();

        public Builder expectedMachineId(String value) {
            this.expectedMachineId = Field.of(value);
            return this;
        }
        public AgentInventoryRequest build() { return new AgentInventoryRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-update-plan request. Protocol v12; authority: local-admin. */
public final class AgentUpdatePlanRequest implements WireValue {
    private final Field<String> expectedMachineId;

    private AgentUpdatePlanRequest(Builder builder) {
        this.expectedMachineId = builder.expectedMachineId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> expectedMachineId() { return expectedMachineId; }

    public static AgentUpdatePlanRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentUpdatePlanRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.optional(object, "expected_machine_id");
        if (!Wire.isMissing(rawExpectedMachineId)) {
            builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentUpdatePlanRequest.expected_machine_id"));
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
        if (!(other instanceof AgentUpdatePlanRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId); }

    @Override
    public String toString() { return "AgentUpdatePlanRequest" + toWire(); }

    public static final class Builder {
        private Field<String> expectedMachineId = Field.omitted();

        public Builder expectedMachineId(String value) {
            this.expectedMachineId = Field.of(value);
            return this;
        }
        public AgentUpdatePlanRequest build() { return new AgentUpdatePlanRequest(this); }
    }
}

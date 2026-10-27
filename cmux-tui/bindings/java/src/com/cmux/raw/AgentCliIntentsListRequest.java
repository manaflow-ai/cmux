// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-intents-list request. Protocol v12; authority: local-admin. */
public final class AgentCliIntentsListRequest implements WireValue {
    private final String expectedMachineId;
    private final String expectedSessionId;

    private AgentCliIntentsListRequest(Builder builder) {
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        if (!builder.expectedSessionIdSet) throw new IllegalArgumentException("expected_session_id is required");
        this.expectedSessionId = Wire.nonNull(builder.expectedSessionId, "expected_session_id");
    }

    public static Builder builder() { return new Builder(); }

    public String expectedMachineId() { return expectedMachineId; }
    public String expectedSessionId() { return expectedSessionId; }

    public static AgentCliIntentsListRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsListRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentCliIntentsListRequest.expected_machine_id"));
        Object rawExpectedSessionId = Wire.required(object, "expected_session_id");
        builder.expectedSessionId(Wire.string(rawExpectedSessionId, "AgentCliIntentsListRequest.expected_session_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "expected_session_id", expectedSessionId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsListRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(expectedSessionId, that.expectedSessionId);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId, expectedSessionId); }

    @Override
    public String toString() { return "AgentCliIntentsListRequest" + toWire(); }

    public static final class Builder {
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private String expectedSessionId;
        private boolean expectedSessionIdSet;

        public Builder expectedMachineId(String value) {
            this.expectedMachineId = value;
            this.expectedMachineIdSet = true;
            return this;
        }
        public Builder expectedSessionId(String value) {
            this.expectedSessionId = value;
            this.expectedSessionIdSet = true;
            return this;
        }
        public AgentCliIntentsListRequest build() { return new AgentCliIntentsListRequest(this); }
    }
}

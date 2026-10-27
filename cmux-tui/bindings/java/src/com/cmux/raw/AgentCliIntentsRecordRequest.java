// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-intents-record request. Protocol v12; authority: local-admin. */
public final class AgentCliIntentsRecordRequest implements WireValue {
    private final String expectedMachineId;
    private final String expectedSessionId;
    private final List<AgentCLIIntent> intents;

    private AgentCliIntentsRecordRequest(Builder builder) {
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        if (!builder.expectedSessionIdSet) throw new IllegalArgumentException("expected_session_id is required");
        this.expectedSessionId = Wire.nonNull(builder.expectedSessionId, "expected_session_id");
        if (!builder.intentsSet) throw new IllegalArgumentException("intents is required");
        this.intents = List.copyOf(Wire.nonNull(builder.intents, "intents"));
    }

    public static Builder builder() { return new Builder(); }

    public String expectedMachineId() { return expectedMachineId; }
    public String expectedSessionId() { return expectedSessionId; }
    public List<AgentCLIIntent> intents() { return intents; }

    public static AgentCliIntentsRecordRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsRecordRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentCliIntentsRecordRequest.expected_machine_id"));
        Object rawExpectedSessionId = Wire.required(object, "expected_session_id");
        builder.expectedSessionId(Wire.string(rawExpectedSessionId, "AgentCliIntentsRecordRequest.expected_session_id"));
        Object rawIntents = Wire.required(object, "intents");
        builder.intents(Wire.array(rawIntents, "AgentCliIntentsRecordRequest.intents", item -> AgentCLIIntent.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "expected_session_id", expectedSessionId);
        Wire.put(object, "intents", intents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsRecordRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(expectedSessionId, that.expectedSessionId) && Objects.equals(intents, that.intents);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId, expectedSessionId, intents); }

    @Override
    public String toString() { return "AgentCliIntentsRecordRequest" + toWire(); }

    public static final class Builder {
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private String expectedSessionId;
        private boolean expectedSessionIdSet;
        private List<AgentCLIIntent> intents;
        private boolean intentsSet;

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
        public Builder intents(List<AgentCLIIntent> value) {
            this.intents = value;
            this.intentsSet = true;
            return this;
        }
        public AgentCliIntentsRecordRequest build() { return new AgentCliIntentsRecordRequest(this); }
    }
}

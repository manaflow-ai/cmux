// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-intents-settle request. Protocol v12; authority: local-admin. */
public final class AgentCliIntentsSettleRequest implements WireValue {
    private final String expectedMachineId;
    private final String expectedSessionId;
    private final List<String> keys;

    private AgentCliIntentsSettleRequest(Builder builder) {
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        if (!builder.expectedSessionIdSet) throw new IllegalArgumentException("expected_session_id is required");
        this.expectedSessionId = Wire.nonNull(builder.expectedSessionId, "expected_session_id");
        if (!builder.keysSet) throw new IllegalArgumentException("keys is required");
        this.keys = List.copyOf(Wire.nonNull(builder.keys, "keys"));
    }

    public static Builder builder() { return new Builder(); }

    public String expectedMachineId() { return expectedMachineId; }
    public String expectedSessionId() { return expectedSessionId; }
    public List<String> keys() { return keys; }

    public static AgentCliIntentsSettleRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsSettleRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentCliIntentsSettleRequest.expected_machine_id"));
        Object rawExpectedSessionId = Wire.required(object, "expected_session_id");
        builder.expectedSessionId(Wire.string(rawExpectedSessionId, "AgentCliIntentsSettleRequest.expected_session_id"));
        Object rawKeys = Wire.required(object, "keys");
        builder.keys(Wire.array(rawKeys, "AgentCliIntentsSettleRequest.keys", item -> Wire.string(item, "AgentCliIntentsSettleRequest.keys item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "expected_session_id", expectedSessionId);
        Wire.put(object, "keys", keys);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsSettleRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(expectedSessionId, that.expectedSessionId) && Objects.equals(keys, that.keys);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId, expectedSessionId, keys); }

    @Override
    public String toString() { return "AgentCliIntentsSettleRequest" + toWire(); }

    public static final class Builder {
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private String expectedSessionId;
        private boolean expectedSessionIdSet;
        private List<String> keys;
        private boolean keysSet;

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
        public Builder keys(List<String> value) {
            this.keys = value;
            this.keysSet = true;
            return this;
        }
        public AgentCliIntentsSettleRequest build() { return new AgentCliIntentsSettleRequest(this); }
    }
}

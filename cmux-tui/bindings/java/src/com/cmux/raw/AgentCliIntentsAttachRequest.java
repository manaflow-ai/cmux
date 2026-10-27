// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-intents-attach request. Protocol v12; authority: local-admin. */
public final class AgentCliIntentsAttachRequest implements WireValue {
    private final String expectedMachineId;
    private final String expectedSessionId;
    private final String key;
    private final AgentCLIJobReceipt receipt;

    private AgentCliIntentsAttachRequest(Builder builder) {
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        if (!builder.expectedSessionIdSet) throw new IllegalArgumentException("expected_session_id is required");
        this.expectedSessionId = Wire.nonNull(builder.expectedSessionId, "expected_session_id");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.receiptSet) throw new IllegalArgumentException("receipt is required");
        this.receipt = Wire.nonNull(builder.receipt, "receipt");
    }

    public static Builder builder() { return new Builder(); }

    public String expectedMachineId() { return expectedMachineId; }
    public String expectedSessionId() { return expectedSessionId; }
    public String key() { return key; }
    public AgentCLIJobReceipt receipt() { return receipt; }

    public static AgentCliIntentsAttachRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsAttachRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentCliIntentsAttachRequest.expected_machine_id"));
        Object rawExpectedSessionId = Wire.required(object, "expected_session_id");
        builder.expectedSessionId(Wire.string(rawExpectedSessionId, "AgentCliIntentsAttachRequest.expected_session_id"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "AgentCliIntentsAttachRequest.key"));
        Object rawReceipt = Wire.required(object, "receipt");
        builder.receipt(AgentCLIJobReceipt.fromWire(rawReceipt));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "expected_session_id", expectedSessionId);
        Wire.put(object, "key", key);
        Wire.put(object, "receipt", receipt);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsAttachRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(expectedSessionId, that.expectedSessionId) && Objects.equals(key, that.key) && Objects.equals(receipt, that.receipt);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId, expectedSessionId, key, receipt); }

    @Override
    public String toString() { return "AgentCliIntentsAttachRequest" + toWire(); }

    public static final class Builder {
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private String expectedSessionId;
        private boolean expectedSessionIdSet;
        private String key;
        private boolean keySet;
        private AgentCLIJobReceipt receipt;
        private boolean receiptSet;

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
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder receipt(AgentCLIJobReceipt value) {
            this.receipt = value;
            this.receiptSet = true;
            return this;
        }
        public AgentCliIntentsAttachRequest build() { return new AgentCliIntentsAttachRequest(this); }
    }
}

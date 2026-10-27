// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-inventory-watch request. Protocol v12; authority: local-admin. */
public final class AgentInventoryWatchRequest implements WireValue {
    /** Only with enabled:true: an unavailable, unsupported or busy refusal carries data {machine, admission:"not_admitted"} when this connection holds no lease. */
    private final Field<Boolean> admissionReceipt;
    /** true opens (or acknowledges again) this connection's lease; false retires it without an ended event. */
    private final boolean enabled;
    /** Identity fence: the canonical public machine id the caller expects; another daemon refuses with agent_inventory.owner_mismatch. Never a routing selector. */
    private final String expectedMachineId;
    /** Only with enabled:false: retire the lease only while it has this id. */
    private final Field<String> expectedWatchId;

    private AgentInventoryWatchRequest(Builder builder) {
        this.admissionReceipt = builder.admissionReceipt;
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        this.expectedWatchId = builder.expectedWatchId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> admissionReceipt() { return admissionReceipt; }
    public boolean enabled() { return enabled; }
    public String expectedMachineId() { return expectedMachineId; }
    public Field<String> expectedWatchId() { return expectedWatchId; }

    public static AgentInventoryWatchRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryWatchRequest");
        Builder builder = builder();
        Object rawAdmissionReceipt = Wire.optional(object, "admission_receipt");
        if (!Wire.isMissing(rawAdmissionReceipt)) {
            builder.admissionReceipt(Wire.bool(rawAdmissionReceipt, "AgentInventoryWatchRequest.admission_receipt"));
        }
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "AgentInventoryWatchRequest.enabled"));
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentInventoryWatchRequest.expected_machine_id"));
        Object rawExpectedWatchId = Wire.optional(object, "expected_watch_id");
        if (!Wire.isMissing(rawExpectedWatchId)) {
            builder.expectedWatchId(Wire.string(rawExpectedWatchId, "AgentInventoryWatchRequest.expected_watch_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "admission_receipt", admissionReceipt);
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "expected_watch_id", expectedWatchId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryWatchRequest that)) return false;
        return Objects.equals(admissionReceipt, that.admissionReceipt) && Objects.equals(enabled, that.enabled) && Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(expectedWatchId, that.expectedWatchId);
    }

    @Override
    public int hashCode() { return Objects.hash(admissionReceipt, enabled, expectedMachineId, expectedWatchId); }

    @Override
    public String toString() { return "AgentInventoryWatchRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> admissionReceipt = Field.omitted();
        private Boolean enabled;
        private boolean enabledSet;
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private Field<String> expectedWatchId = Field.omitted();

        public Builder admissionReceipt(Boolean value) {
            this.admissionReceipt = Field.of(value);
            return this;
        }
        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public Builder expectedMachineId(String value) {
            this.expectedMachineId = value;
            this.expectedMachineIdSet = true;
            return this;
        }
        public Builder expectedWatchId(String value) {
            this.expectedWatchId = Field.of(value);
            return this;
        }
        public AgentInventoryWatchRequest build() { return new AgentInventoryWatchRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-update-apply request. Protocol v12; authority: local-admin. */
public final class AgentUpdateApplyRequest implements WireValue {
    private final Field<Boolean> continueThreads;
    private final Field<String> expectedMachineId;
    private final List<String> ids;

    private AgentUpdateApplyRequest(Builder builder) {
        this.continueThreads = builder.continueThreads;
        this.expectedMachineId = builder.expectedMachineId;
        if (!builder.idsSet) throw new IllegalArgumentException("ids is required");
        this.ids = List.copyOf(Wire.nonNull(builder.ids, "ids"));
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> continueThreads() { return continueThreads; }
    public Field<String> expectedMachineId() { return expectedMachineId; }
    public List<String> ids() { return ids; }

    public static AgentUpdateApplyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentUpdateApplyRequest");
        Builder builder = builder();
        Object rawContinueThreads = Wire.optional(object, "continue_threads");
        if (!Wire.isMissing(rawContinueThreads)) {
            builder.continueThreads(Wire.bool(rawContinueThreads, "AgentUpdateApplyRequest.continue_threads"));
        }
        Object rawExpectedMachineId = Wire.optional(object, "expected_machine_id");
        if (!Wire.isMissing(rawExpectedMachineId)) {
            builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentUpdateApplyRequest.expected_machine_id"));
        }
        Object rawIds = Wire.required(object, "ids");
        builder.ids(Wire.array(rawIds, "AgentUpdateApplyRequest.ids", item -> Wire.string(item, "AgentUpdateApplyRequest.ids item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "continue_threads", continueThreads);
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "ids", ids);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentUpdateApplyRequest that)) return false;
        return Objects.equals(continueThreads, that.continueThreads) && Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(ids, that.ids);
    }

    @Override
    public int hashCode() { return Objects.hash(continueThreads, expectedMachineId, ids); }

    @Override
    public String toString() { return "AgentUpdateApplyRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> continueThreads = Field.omitted();
        private Field<String> expectedMachineId = Field.omitted();
        private List<String> ids;
        private boolean idsSet;

        public Builder continueThreads(Boolean value) {
            this.continueThreads = Field.of(value);
            return this;
        }
        public Builder expectedMachineId(String value) {
            this.expectedMachineId = Field.of(value);
            return this;
        }
        public Builder ids(List<String> value) {
            this.ids = value;
            this.idsSet = true;
            return this;
        }
        public AgentUpdateApplyRequest build() { return new AgentUpdateApplyRequest(this); }
    }
}

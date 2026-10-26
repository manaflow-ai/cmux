// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable machine-catalog-publish request. Protocol v12; authority: local-admin. */
public final class MachineCatalogPublishRequest implements WireValue {
    private final String expectedMachineId;
    private final List<MachineCatalogEntry> machines;
    private final UInt64 sequence;

    private MachineCatalogPublishRequest(Builder builder) {
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        if (!builder.machinesSet) throw new IllegalArgumentException("machines is required");
        this.machines = List.copyOf(Wire.nonNull(builder.machines, "machines"));
        if (!builder.sequenceSet) throw new IllegalArgumentException("sequence is required");
        this.sequence = Wire.nonNull(builder.sequence, "sequence");
    }

    public static Builder builder() { return new Builder(); }

    public String expectedMachineId() { return expectedMachineId; }
    public List<MachineCatalogEntry> machines() { return machines; }
    public UInt64 sequence() { return sequence; }

    public static MachineCatalogPublishRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineCatalogPublishRequest");
        Builder builder = builder();
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "MachineCatalogPublishRequest.expected_machine_id"));
        Object rawMachines = Wire.required(object, "machines");
        builder.machines(Wire.array(rawMachines, "MachineCatalogPublishRequest.machines", item -> MachineCatalogEntry.fromWire(item)));
        Object rawSequence = Wire.required(object, "sequence");
        builder.sequence(Wire.uint64(rawSequence, "MachineCatalogPublishRequest.sequence"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "machines", machines);
        Wire.put(object, "sequence", sequence);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineCatalogPublishRequest that)) return false;
        return Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(machines, that.machines) && Objects.equals(sequence, that.sequence);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedMachineId, machines, sequence); }

    @Override
    public String toString() { return "MachineCatalogPublishRequest" + toWire(); }

    public static final class Builder {
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private List<MachineCatalogEntry> machines;
        private boolean machinesSet;
        private UInt64 sequence;
        private boolean sequenceSet;

        public Builder expectedMachineId(String value) {
            this.expectedMachineId = value;
            this.expectedMachineIdSet = true;
            return this;
        }
        public Builder machines(List<MachineCatalogEntry> value) {
            this.machines = value;
            this.machinesSet = true;
            return this;
        }
        public Builder sequence(UInt64 value) {
            this.sequence = value;
            this.sequenceSet = true;
            return this;
        }
        public MachineCatalogPublishRequest build() { return new MachineCatalogPublishRequest(this); }
    }
}

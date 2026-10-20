// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable identify request. Protocol v5; authority: control. */
public final class IdentifyRequest implements WireValue {
    private final Field<Boolean> machineMetadata;
    private final Field<Boolean> revisions;

    private IdentifyRequest(Builder builder) {
        this.machineMetadata = builder.machineMetadata;
        this.revisions = builder.revisions;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> machineMetadata() { return machineMetadata; }
    public Field<Boolean> revisions() { return revisions; }

    public static IdentifyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdentifyRequest");
        Builder builder = builder();
        Object rawMachineMetadata = Wire.optional(object, "machine_metadata");
        if (!Wire.isMissing(rawMachineMetadata)) {
            builder.machineMetadata(Wire.bool(rawMachineMetadata, "IdentifyRequest.machine_metadata"));
        }
        Object rawRevisions = Wire.optional(object, "revisions");
        if (!Wire.isMissing(rawRevisions)) {
            builder.revisions(Wire.bool(rawRevisions, "IdentifyRequest.revisions"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "machine_metadata", machineMetadata);
        Wire.put(object, "revisions", revisions);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdentifyRequest that)) return false;
        return Objects.equals(machineMetadata, that.machineMetadata) && Objects.equals(revisions, that.revisions);
    }

    @Override
    public int hashCode() { return Objects.hash(machineMetadata, revisions); }

    @Override
    public String toString() { return "IdentifyRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> machineMetadata = Field.omitted();
        private Field<Boolean> revisions = Field.omitted();

        public Builder machineMetadata(Boolean value) {
            this.machineMetadata = Field.of(value);
            return this;
        }
        public Builder revisions(Boolean value) {
            this.revisions = Field.of(value);
            return this;
        }
        public IdentifyRequest build() { return new IdentifyRequest(this); }
    }
}

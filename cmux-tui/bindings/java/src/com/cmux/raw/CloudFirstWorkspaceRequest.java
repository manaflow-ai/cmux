// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-first-workspace request. Protocol v12; authority: local-admin. */
public final class CloudFirstWorkspaceRequest implements WireValue {
    private final String machineId;
    private final Field<Boolean> welcome;
    private final Field<String> workspace;

    private CloudFirstWorkspaceRequest(Builder builder) {
        if (!builder.machineIdSet) throw new IllegalArgumentException("machine_id is required");
        this.machineId = Wire.nonNull(builder.machineId, "machine_id");
        this.welcome = builder.welcome;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public String machineId() { return machineId; }
    public Field<Boolean> welcome() { return welcome; }
    public Field<String> workspace() { return workspace; }

    public static CloudFirstWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudFirstWorkspaceRequest");
        Builder builder = builder();
        Object rawMachineId = Wire.required(object, "machine_id");
        builder.machineId(Wire.string(rawMachineId, "CloudFirstWorkspaceRequest.machine_id"));
        Object rawWelcome = Wire.optional(object, "welcome");
        if (!Wire.isMissing(rawWelcome)) {
            builder.welcome(Wire.bool(rawWelcome, "CloudFirstWorkspaceRequest.welcome"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.string(rawWorkspace, "CloudFirstWorkspaceRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "machine_id", machineId);
        Wire.put(object, "welcome", welcome);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudFirstWorkspaceRequest that)) return false;
        return Objects.equals(machineId, that.machineId) && Objects.equals(welcome, that.welcome) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(machineId, welcome, workspace); }

    @Override
    public String toString() { return "CloudFirstWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private String machineId;
        private boolean machineIdSet;
        private Field<Boolean> welcome = Field.omitted();
        private Field<String> workspace = Field.omitted();

        public Builder machineId(String value) {
            this.machineId = value;
            this.machineIdSet = true;
            return this;
        }
        public Builder welcome(Boolean value) {
            this.welcome = Field.of(value);
            return this;
        }
        public Builder workspace(String value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public CloudFirstWorkspaceRequest build() { return new CloudFirstWorkspaceRequest(this); }
    }
}

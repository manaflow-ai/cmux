// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-workspace-to-group request. Protocol v12; authority: control. */
public final class MoveWorkspaceToGroupRequest implements WireValue {
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    private final Field<String> group;
    private final Field<UInt64> index;
    private final Field<String> key;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final Field<UInt64> workspace;

    private MoveWorkspaceToGroupRequest(Builder builder) {
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.group = builder.group;
        this.index = builder.index;
        this.key = builder.key;
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> group() { return group; }
    public Field<UInt64> index() { return index; }
    public Field<String> key() { return key; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public Field<UInt64> workspace() { return workspace; }

    public static MoveWorkspaceToGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveWorkspaceToGroupRequest");
        Builder builder = builder();
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "MoveWorkspaceToGroupRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "MoveWorkspaceToGroupRequest.expected_revision"));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "MoveWorkspaceToGroupRequest.group"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "MoveWorkspaceToGroupRequest.index"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "MoveWorkspaceToGroupRequest.key"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "MoveWorkspaceToGroupRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "MoveWorkspaceToGroupRequest.origin"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "MoveWorkspaceToGroupRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "key", key);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveWorkspaceToGroupRequest that)) return false;
        return Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(key, that.key) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedGeneration, expectedRevision, group, index, key, mutationId, origin, workspace); }

    @Override
    public String toString() { return "MoveWorkspaceToGroupRequest" + toWire(); }

    public static final class Builder {
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.ofNullable(value);
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public MoveWorkspaceToGroupRequest build() { return new MoveWorkspaceToGroupRequest(this); }
    }
}

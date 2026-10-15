// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable rename-workspace request. Protocol v5; authority: control. */
public final class RenameWorkspaceRequest implements WireValue {
    private final Field<String> expectedGeneration;
    /** The workspace name_revision the caller read; a rename since then fails. */
    private final Field<String> expectedNameRevision;
    private final Field<UInt64> expectedRevision;
    private final Field<String> key;
    private final Field<String> mutationId;
    private final String name;
    private final Field<String> origin;
    /** With source auto, hand the current name back to the automatic namer; name must equal the current name and no expected_name_revision is needed. */
    private final Field<Boolean> release;
    /** Who chose the name; absent is user. An automatic name never replaces a user name and needs expected_generation and expected_name_revision. */
    private final Field<NameSource> source;
    private final Field<UInt64> workspace;

    private RenameWorkspaceRequest(Builder builder) {
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedNameRevision = builder.expectedNameRevision;
        this.expectedRevision = builder.expectedRevision;
        this.key = builder.key;
        this.mutationId = builder.mutationId;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.origin = builder.origin;
        this.release = builder.release;
        this.source = builder.source;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<String> expectedNameRevision() { return expectedNameRevision; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> key() { return key; }
    public Field<String> mutationId() { return mutationId; }
    public String name() { return name; }
    public Field<String> origin() { return origin; }
    public Field<Boolean> release() { return release; }
    public Field<NameSource> source() { return source; }
    public Field<UInt64> workspace() { return workspace; }

    public static RenameWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenameWorkspaceRequest");
        Builder builder = builder();
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "RenameWorkspaceRequest.expected_generation"));
        }
        Object rawExpectedNameRevision = Wire.optional(object, "expected_name_revision");
        if (!Wire.isMissing(rawExpectedNameRevision)) {
            builder.expectedNameRevision(rawExpectedNameRevision == null ? null : Wire.string(rawExpectedNameRevision, "RenameWorkspaceRequest.expected_name_revision"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "RenameWorkspaceRequest.expected_revision"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "RenameWorkspaceRequest.key"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "RenameWorkspaceRequest.mutation_id"));
        }
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "RenameWorkspaceRequest.name"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "RenameWorkspaceRequest.origin"));
        }
        Object rawRelease = Wire.optional(object, "release");
        if (!Wire.isMissing(rawRelease)) {
            builder.release(Wire.bool(rawRelease, "RenameWorkspaceRequest.release"));
        }
        Object rawSource = Wire.optional(object, "source");
        if (!Wire.isMissing(rawSource)) {
            builder.source(rawSource == null ? null : NameSource.fromWire(rawSource));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "RenameWorkspaceRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_name_revision", expectedNameRevision);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "key", key);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "name", name);
        Wire.put(object, "origin", origin);
        Wire.put(object, "release", release);
        Wire.put(object, "source", source);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenameWorkspaceRequest that)) return false;
        return Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedNameRevision, that.expectedNameRevision) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(key, that.key) && Objects.equals(mutationId, that.mutationId) && Objects.equals(name, that.name) && Objects.equals(origin, that.origin) && Objects.equals(release, that.release) && Objects.equals(source, that.source) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedGeneration, expectedNameRevision, expectedRevision, key, mutationId, name, origin, release, source, workspace); }

    @Override
    public String toString() { return "RenameWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private Field<String> expectedGeneration = Field.omitted();
        private Field<String> expectedNameRevision = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private String name;
        private boolean nameSet;
        private Field<String> origin = Field.omitted();
        private Field<Boolean> release = Field.omitted();
        private Field<NameSource> source = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedNameRevision(String value) {
            this.expectedNameRevision = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
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
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder release(Boolean value) {
            this.release = Field.of(value);
            return this;
        }
        public Builder source(NameSource value) {
            this.source = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public RenameWorkspaceRequest build() { return new RenameWorkspaceRequest(this); }
    }
}

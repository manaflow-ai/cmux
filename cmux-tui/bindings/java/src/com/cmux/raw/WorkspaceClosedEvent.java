// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable workspace-closed event. Protocol v7; streams: subscribe-deltas. */
public final class WorkspaceClosedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Workspace entity;
    private final String generation;
    private final UInt64 index;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final String registryId;
    private final UInt64 workspace;
    private final UInt64 workspaceRevision;

    private WorkspaceClosedEvent(Builder builder) {
        if (!builder.entitySet) throw new IllegalArgumentException("entity is required");
        this.entity = Wire.nonNull(builder.entity, "entity");
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
        if (!builder.workspaceRevisionSet) throw new IllegalArgumentException("workspace_revision is required");
        this.workspaceRevision = Wire.nonNull(builder.workspaceRevision, "workspace_revision");
    }

    public static Builder builder() { return new Builder(); }

    public Workspace entity() { return entity; }
    public String generation() { return generation; }
    public UInt64 index() { return index; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public String registryId() { return registryId; }
    public UInt64 workspace() { return workspace; }
    public UInt64 workspaceRevision() { return workspaceRevision; }
    @Override public String event() { return "workspace-closed"; }

    public static WorkspaceClosedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspaceClosedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "workspace-closed", "WorkspaceClosedEvent.event");
        Object rawEntity = Wire.required(object, "entity");
        builder.entity(Workspace.fromWire(rawEntity));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "WorkspaceClosedEvent.generation"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "WorkspaceClosedEvent.index"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(Wire.string(rawMutationId, "WorkspaceClosedEvent.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(Wire.string(rawOrigin, "WorkspaceClosedEvent.origin"));
        }
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "WorkspaceClosedEvent.registry_id"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "WorkspaceClosedEvent.workspace"));
        Object rawWorkspaceRevision = Wire.required(object, "workspace_revision");
        builder.workspaceRevision(Wire.uint64(rawWorkspaceRevision, "WorkspaceClosedEvent.workspace_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "workspace-closed");
        Wire.put(object, "entity", entity);
        Wire.put(object, "generation", generation);
        Wire.put(object, "index", index);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "workspace", workspace);
        Wire.put(object, "workspace_revision", workspaceRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WorkspaceClosedEvent that)) return false;
        return Objects.equals(entity, that.entity) && Objects.equals(generation, that.generation) && Objects.equals(index, that.index) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(registryId, that.registryId) && Objects.equals(workspace, that.workspace) && Objects.equals(workspaceRevision, that.workspaceRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(entity, generation, index, mutationId, origin, registryId, workspace, workspaceRevision); }

    @Override
    public String toString() { return "WorkspaceClosedEvent" + toWire(); }

    public static final class Builder {
        private Workspace entity;
        private boolean entitySet;
        private String generation;
        private boolean generationSet;
        private UInt64 index;
        private boolean indexSet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private String registryId;
        private boolean registryIdSet;
        private UInt64 workspace;
        private boolean workspaceSet;
        private UInt64 workspaceRevision;
        private boolean workspaceRevisionSet;

        public Builder entity(Workspace value) {
            this.entity = value;
            this.entitySet = true;
            return this;
        }
        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.of(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.of(value);
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = value;
            this.registryIdSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public Builder workspaceRevision(UInt64 value) {
            this.workspaceRevision = value;
            this.workspaceRevisionSet = true;
            return this;
        }
        public WorkspaceClosedEvent build() { return new WorkspaceClosedEvent(this); }
    }
}

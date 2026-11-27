// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class WorkspaceMutationResult implements WireValue {
    private final Field<Boolean> changed;
    private final String generation;
    private final UInt64 index;
    private final String key;
    private final String registryId;
    private final boolean replayed;
    private final UInt64 workspace;
    private final UInt64 workspaceRevision;

    private WorkspaceMutationResult(Builder builder) {
        this.changed = builder.changed;
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
        if (!builder.workspaceRevisionSet) throw new IllegalArgumentException("workspace_revision is required");
        this.workspaceRevision = Wire.nonNull(builder.workspaceRevision, "workspace_revision");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> changed() { return changed; }
    public String generation() { return generation; }
    public UInt64 index() { return index; }
    public String key() { return key; }
    public String registryId() { return registryId; }
    public boolean replayed() { return replayed; }
    public UInt64 workspace() { return workspace; }
    public UInt64 workspaceRevision() { return workspaceRevision; }

    public static WorkspaceMutationResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspaceMutationResult");
        Builder builder = builder();
        Object rawChanged = Wire.optional(object, "changed");
        if (!Wire.isMissing(rawChanged)) {
            builder.changed(Wire.bool(rawChanged, "WorkspaceMutationResult.changed"));
        }
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "WorkspaceMutationResult.generation"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "WorkspaceMutationResult.index"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "WorkspaceMutationResult.key"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "WorkspaceMutationResult.registry_id"));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "WorkspaceMutationResult.replayed"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "WorkspaceMutationResult.workspace"));
        Object rawWorkspaceRevision = Wire.required(object, "workspace_revision");
        builder.workspaceRevision(Wire.uint64(rawWorkspaceRevision, "WorkspaceMutationResult.workspace_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "generation", generation);
        Wire.put(object, "index", index);
        Wire.put(object, "key", key);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "workspace", workspace);
        Wire.put(object, "workspace_revision", workspaceRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WorkspaceMutationResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(generation, that.generation) && Objects.equals(index, that.index) && Objects.equals(key, that.key) && Objects.equals(registryId, that.registryId) && Objects.equals(replayed, that.replayed) && Objects.equals(workspace, that.workspace) && Objects.equals(workspaceRevision, that.workspaceRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, generation, index, key, registryId, replayed, workspace, workspaceRevision); }

    @Override
    public String toString() { return "WorkspaceMutationResult" + toWire(); }

    public static final class Builder {
        private Field<Boolean> changed = Field.omitted();
        private String generation;
        private boolean generationSet;
        private UInt64 index;
        private boolean indexSet;
        private String key;
        private boolean keySet;
        private String registryId;
        private boolean registryIdSet;
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 workspace;
        private boolean workspaceSet;
        private UInt64 workspaceRevision;
        private boolean workspaceRevisionSet;

        public Builder changed(Boolean value) {
            this.changed = Field.of(value);
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
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = value;
            this.registryIdSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
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
        public WorkspaceMutationResult build() { return new WorkspaceMutationResult(this); }
    }
}

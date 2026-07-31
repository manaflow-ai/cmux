// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ProviderWorkspaceMutationResult implements WireValue {
    private final String key;
    private final UInt64 workspace;
    private final UInt64 workspaceRevision;

    private ProviderWorkspaceMutationResult(Builder builder) {
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
        if (!builder.workspaceRevisionSet) throw new IllegalArgumentException("workspace_revision is required");
        this.workspaceRevision = Wire.nonNull(builder.workspaceRevision, "workspace_revision");
    }

    public static Builder builder() { return new Builder(); }

    public String key() { return key; }
    public UInt64 workspace() { return workspace; }
    public UInt64 workspaceRevision() { return workspaceRevision; }

    public static ProviderWorkspaceMutationResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ProviderWorkspaceMutationResult");
        Builder builder = builder();
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "ProviderWorkspaceMutationResult.key"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "ProviderWorkspaceMutationResult.workspace"));
        Object rawWorkspaceRevision = Wire.required(object, "workspace_revision");
        builder.workspaceRevision(Wire.uint64(rawWorkspaceRevision, "ProviderWorkspaceMutationResult.workspace_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "key", key);
        Wire.put(object, "workspace", workspace);
        Wire.put(object, "workspace_revision", workspaceRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ProviderWorkspaceMutationResult that)) return false;
        return Objects.equals(key, that.key) && Objects.equals(workspace, that.workspace) && Objects.equals(workspaceRevision, that.workspaceRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(key, workspace, workspaceRevision); }

    @Override
    public String toString() { return "ProviderWorkspaceMutationResult" + toWire(); }

    public static final class Builder {
        private String key;
        private boolean keySet;
        private UInt64 workspace;
        private boolean workspaceSet;
        private UInt64 workspaceRevision;
        private boolean workspaceRevisionSet;

        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
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
        public ProviderWorkspaceMutationResult build() { return new ProviderWorkspaceMutationResult(this); }
    }
}

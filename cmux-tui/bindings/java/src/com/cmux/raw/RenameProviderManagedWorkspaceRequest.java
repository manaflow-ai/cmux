// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable rename-provider-managed-workspace request. Protocol v9; authority: provider-authority. */
public final class RenameProviderManagedWorkspaceRequest implements WireValue {
    private final String authority;
    private final String key;
    private final String name;
    private final UInt64 workspace;

    private RenameProviderManagedWorkspaceRequest(Builder builder) {
        if (!builder.authoritySet) throw new IllegalArgumentException("authority is required");
        this.authority = Wire.nonNull(builder.authority, "authority");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public String authority() { return authority; }
    public String key() { return key; }
    public String name() { return name; }
    public UInt64 workspace() { return workspace; }

    public static RenameProviderManagedWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenameProviderManagedWorkspaceRequest");
        Builder builder = builder();
        Object rawAuthority = Wire.required(object, "authority");
        builder.authority(Wire.string(rawAuthority, "RenameProviderManagedWorkspaceRequest.authority"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "RenameProviderManagedWorkspaceRequest.key"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "RenameProviderManagedWorkspaceRequest.name"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "RenameProviderManagedWorkspaceRequest.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authority", authority);
        Wire.put(object, "key", key);
        Wire.put(object, "name", name);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenameProviderManagedWorkspaceRequest that)) return false;
        return Objects.equals(authority, that.authority) && Objects.equals(key, that.key) && Objects.equals(name, that.name) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(authority, key, name, workspace); }

    @Override
    public String toString() { return "RenameProviderManagedWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private String authority;
        private boolean authoritySet;
        private String key;
        private boolean keySet;
        private String name;
        private boolean nameSet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder authority(String value) {
            this.authority = value;
            this.authoritySet = true;
            return this;
        }
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public RenameProviderManagedWorkspaceRequest build() { return new RenameProviderManagedWorkspaceRequest(this); }
    }
}

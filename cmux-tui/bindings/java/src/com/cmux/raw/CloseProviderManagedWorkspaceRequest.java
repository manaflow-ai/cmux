// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-provider-managed-workspace request. Protocol v9; authority: provider-authority. */
public final class CloseProviderManagedWorkspaceRequest implements WireValue {
    private final String authority;
    private final String key;
    private final UInt64 workspace;

    private CloseProviderManagedWorkspaceRequest(Builder builder) {
        if (!builder.authoritySet) throw new IllegalArgumentException("authority is required");
        this.authority = Wire.nonNull(builder.authority, "authority");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public String authority() { return authority; }
    public String key() { return key; }
    public UInt64 workspace() { return workspace; }

    public static CloseProviderManagedWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseProviderManagedWorkspaceRequest");
        Builder builder = builder();
        Object rawAuthority = Wire.required(object, "authority");
        builder.authority(Wire.string(rawAuthority, "CloseProviderManagedWorkspaceRequest.authority"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "CloseProviderManagedWorkspaceRequest.key"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "CloseProviderManagedWorkspaceRequest.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authority", authority);
        Wire.put(object, "key", key);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseProviderManagedWorkspaceRequest that)) return false;
        return Objects.equals(authority, that.authority) && Objects.equals(key, that.key) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(authority, key, workspace); }

    @Override
    public String toString() { return "CloseProviderManagedWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private String authority;
        private boolean authoritySet;
        private String key;
        private boolean keySet;
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
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public CloseProviderManagedWorkspaceRequest build() { return new CloseProviderManagedWorkspaceRequest(this); }
    }
}

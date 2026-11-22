// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable unpin-workspace request. Protocol v12; authority: control. */
public final class UnpinWorkspaceRequest implements WireValue {
    private final String sessionId;
    private final String workspaceKey;

    private UnpinWorkspaceRequest(Builder builder) {
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        if (!builder.workspaceKeySet) throw new IllegalArgumentException("workspace_key is required");
        this.workspaceKey = Wire.nonNull(builder.workspaceKey, "workspace_key");
    }

    public static Builder builder() { return new Builder(); }

    public String sessionId() { return sessionId; }
    public String workspaceKey() { return workspaceKey; }

    public static UnpinWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UnpinWorkspaceRequest");
        Builder builder = builder();
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "UnpinWorkspaceRequest.session_id"));
        Object rawWorkspaceKey = Wire.required(object, "workspace_key");
        builder.workspaceKey(Wire.string(rawWorkspaceKey, "UnpinWorkspaceRequest.workspace_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "workspace_key", workspaceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UnpinWorkspaceRequest that)) return false;
        return Objects.equals(sessionId, that.sessionId) && Objects.equals(workspaceKey, that.workspaceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(sessionId, workspaceKey); }

    @Override
    public String toString() { return "UnpinWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private String sessionId;
        private boolean sessionIdSet;
        private String workspaceKey;
        private boolean workspaceKeySet;

        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder workspaceKey(String value) {
            this.workspaceKey = value;
            this.workspaceKeySet = true;
            return this;
        }
        public UnpinWorkspaceRequest build() { return new UnpinWorkspaceRequest(this); }
    }
}

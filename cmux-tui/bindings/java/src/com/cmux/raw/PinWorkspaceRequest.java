// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable pin-workspace request. Protocol v12; authority: control. */
public final class PinWorkspaceRequest implements WireValue {
    private final String profile;
    private final String sessionId;
    private final String workspaceKey;

    private PinWorkspaceRequest(Builder builder) {
        if (!builder.profileSet) throw new IllegalArgumentException("profile is required");
        this.profile = Wire.nonNull(builder.profile, "profile");
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        if (!builder.workspaceKeySet) throw new IllegalArgumentException("workspace_key is required");
        this.workspaceKey = Wire.nonNull(builder.workspaceKey, "workspace_key");
    }

    public static Builder builder() { return new Builder(); }

    public String profile() { return profile; }
    public String sessionId() { return sessionId; }
    public String workspaceKey() { return workspaceKey; }

    public static PinWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PinWorkspaceRequest");
        Builder builder = builder();
        Object rawProfile = Wire.required(object, "profile");
        builder.profile(Wire.string(rawProfile, "PinWorkspaceRequest.profile"));
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "PinWorkspaceRequest.session_id"));
        Object rawWorkspaceKey = Wire.required(object, "workspace_key");
        builder.workspaceKey(Wire.string(rawWorkspaceKey, "PinWorkspaceRequest.workspace_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "profile", profile);
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "workspace_key", workspaceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PinWorkspaceRequest that)) return false;
        return Objects.equals(profile, that.profile) && Objects.equals(sessionId, that.sessionId) && Objects.equals(workspaceKey, that.workspaceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(profile, sessionId, workspaceKey); }

    @Override
    public String toString() { return "PinWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private String profile;
        private boolean profileSet;
        private String sessionId;
        private boolean sessionIdSet;
        private String workspaceKey;
        private boolean workspaceKeySet;

        public Builder profile(String value) {
            this.profile = value;
            this.profileSet = true;
            return this;
        }
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
        public PinWorkspaceRequest build() { return new PinWorkspaceRequest(this); }
    }
}

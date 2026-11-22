// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-personal-workspace request. Protocol v12; authority: control. */
public final class SetPersonalWorkspaceRequest implements WireValue {
    private final Field<String> browserProfileId;
    private final Field<String> group;
    private final Field<UInt64> index;
    private final String sessionId;
    private final Field<String> theme;
    private final String workspaceKey;

    private SetPersonalWorkspaceRequest(Builder builder) {
        this.browserProfileId = builder.browserProfileId;
        this.group = builder.group;
        this.index = builder.index;
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        this.theme = builder.theme;
        if (!builder.workspaceKeySet) throw new IllegalArgumentException("workspace_key is required");
        this.workspaceKey = Wire.nonNull(builder.workspaceKey, "workspace_key");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> browserProfileId() { return browserProfileId; }
    public Field<String> group() { return group; }
    public Field<UInt64> index() { return index; }
    public String sessionId() { return sessionId; }
    public Field<String> theme() { return theme; }
    public String workspaceKey() { return workspaceKey; }

    public static SetPersonalWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetPersonalWorkspaceRequest");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.optional(object, "browser_profile_id");
        if (!Wire.isMissing(rawBrowserProfileId)) {
            builder.browserProfileId(rawBrowserProfileId == null ? null : Wire.string(rawBrowserProfileId, "SetPersonalWorkspaceRequest.browser_profile_id"));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "SetPersonalWorkspaceRequest.group"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "SetPersonalWorkspaceRequest.index"));
        }
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "SetPersonalWorkspaceRequest.session_id"));
        Object rawTheme = Wire.optional(object, "theme");
        if (!Wire.isMissing(rawTheme)) {
            builder.theme(rawTheme == null ? null : Wire.string(rawTheme, "SetPersonalWorkspaceRequest.theme"));
        }
        Object rawWorkspaceKey = Wire.required(object, "workspace_key");
        builder.workspaceKey(Wire.string(rawWorkspaceKey, "SetPersonalWorkspaceRequest.workspace_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "theme", theme);
        Wire.put(object, "workspace_key", workspaceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetPersonalWorkspaceRequest that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(sessionId, that.sessionId) && Objects.equals(theme, that.theme) && Objects.equals(workspaceKey, that.workspaceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId, group, index, sessionId, theme, workspaceKey); }

    @Override
    public String toString() { return "SetPersonalWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private Field<String> browserProfileId = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private String sessionId;
        private boolean sessionIdSet;
        private Field<String> theme = Field.omitted();
        private String workspaceKey;
        private boolean workspaceKeySet;

        public Builder browserProfileId(String value) {
            this.browserProfileId = Field.ofNullable(value);
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
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder theme(String value) {
            this.theme = Field.ofNullable(value);
            return this;
        }
        public Builder workspaceKey(String value) {
            this.workspaceKey = value;
            this.workspaceKeySet = true;
            return this;
        }
        public SetPersonalWorkspaceRequest build() { return new SetPersonalWorkspaceRequest(this); }
    }
}

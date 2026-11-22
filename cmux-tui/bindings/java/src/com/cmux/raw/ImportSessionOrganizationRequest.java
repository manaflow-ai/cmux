// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable import-session-organization request. Protocol v12; authority: control. */
public final class ImportSessionOrganizationRequest implements WireValue {
    private final Field<List<Object>> groups;
    private final String sessionId;
    private final Field<List<Object>> workspaces;

    private ImportSessionOrganizationRequest(Builder builder) {
        this.groups = builder.groups.map(value -> List.copyOf(value));
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        this.workspaces = builder.workspaces.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<Object>> groups() { return groups; }
    public String sessionId() { return sessionId; }
    public Field<List<Object>> workspaces() { return workspaces; }

    public static ImportSessionOrganizationRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ImportSessionOrganizationRequest");
        Builder builder = builder();
        Object rawGroups = Wire.optional(object, "groups");
        if (!Wire.isMissing(rawGroups)) {
            builder.groups(Wire.array(rawGroups, "ImportSessionOrganizationRequest.groups", item -> Wire.immutableJson(item)));
        }
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "ImportSessionOrganizationRequest.session_id"));
        Object rawWorkspaces = Wire.optional(object, "workspaces");
        if (!Wire.isMissing(rawWorkspaces)) {
            builder.workspaces(Wire.array(rawWorkspaces, "ImportSessionOrganizationRequest.workspaces", item -> Wire.immutableJson(item)));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "groups", groups);
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "workspaces", workspaces);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ImportSessionOrganizationRequest that)) return false;
        return Objects.equals(groups, that.groups) && Objects.equals(sessionId, that.sessionId) && Objects.equals(workspaces, that.workspaces);
    }

    @Override
    public int hashCode() { return Objects.hash(groups, sessionId, workspaces); }

    @Override
    public String toString() { return "ImportSessionOrganizationRequest" + toWire(); }

    public static final class Builder {
        private Field<List<Object>> groups = Field.omitted();
        private String sessionId;
        private boolean sessionIdSet;
        private Field<List<Object>> workspaces = Field.omitted();

        public Builder groups(List<Object> value) {
            this.groups = Field.of(value);
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder workspaces(List<Object> value) {
            this.workspaces = Field.of(value);
            return this;
        }
        public ImportSessionOrganizationRequest build() { return new ImportSessionOrganizationRequest(this); }
    }
}

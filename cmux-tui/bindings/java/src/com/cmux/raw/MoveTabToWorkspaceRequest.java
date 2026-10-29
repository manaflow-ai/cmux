// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-to-workspace request. Protocol v12; authority: control. */
public final class MoveTabToWorkspaceRequest implements WireValue {
    private final UInt64 surface;
    private final Field<UInt64> workspace;

    private MoveTabToWorkspaceRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public Field<UInt64> workspace() { return workspace; }

    public static MoveTabToWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabToWorkspaceRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabToWorkspaceRequest.surface"));
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "MoveTabToWorkspaceRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabToWorkspaceRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, workspace); }

    @Override
    public String toString() { return "MoveTabToWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<UInt64> workspace = Field.omitted();

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public MoveTabToWorkspaceRequest build() { return new MoveTabToWorkspaceRequest(this); }
    }
}

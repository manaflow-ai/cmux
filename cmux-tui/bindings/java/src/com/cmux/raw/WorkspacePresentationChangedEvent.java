// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable workspace-presentation-changed event. Protocol v12; streams: subscribe-deltas. */
public final class WorkspacePresentationChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Workspace entity;
    private final UInt64 workspace;

    private WorkspacePresentationChangedEvent(Builder builder) {
        if (!builder.entitySet) throw new IllegalArgumentException("entity is required");
        this.entity = Wire.nonNull(builder.entity, "entity");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public Workspace entity() { return entity; }
    public UInt64 workspace() { return workspace; }
    @Override public String event() { return "workspace-presentation-changed"; }

    public static WorkspacePresentationChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspacePresentationChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "workspace-presentation-changed", "WorkspacePresentationChangedEvent.event");
        Object rawEntity = Wire.required(object, "entity");
        builder.entity(Workspace.fromWire(rawEntity));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "WorkspacePresentationChangedEvent.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "workspace-presentation-changed");
        Wire.put(object, "entity", entity);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WorkspacePresentationChangedEvent that)) return false;
        return Objects.equals(entity, that.entity) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(entity, workspace); }

    @Override
    public String toString() { return "WorkspacePresentationChangedEvent" + toWire(); }

    public static final class Builder {
        private Workspace entity;
        private boolean entitySet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder entity(Workspace value) {
            this.entity = value;
            this.entitySet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public WorkspacePresentationChangedEvent build() { return new WorkspacePresentationChangedEvent(this); }
    }
}

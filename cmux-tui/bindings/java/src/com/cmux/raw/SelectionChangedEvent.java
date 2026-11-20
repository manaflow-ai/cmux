// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable selection-changed event. Protocol v12; streams: subscribe-deltas. */
public final class SelectionChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final boolean active;
    private final UInt64 activeWorkspace;
    private final List<SelectionScreen> screens;
    private final UInt64 workspace;

    private SelectionChangedEvent(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        if (!builder.activeWorkspaceSet) throw new IllegalArgumentException("active_workspace is required");
        this.activeWorkspace = builder.activeWorkspace;
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public UInt64 activeWorkspace() { return activeWorkspace; }
    public List<SelectionScreen> screens() { return screens; }
    public UInt64 workspace() { return workspace; }
    @Override public String event() { return "selection-changed"; }

    public static SelectionChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SelectionChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "selection-changed", "SelectionChangedEvent.event");
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "SelectionChangedEvent.active"));
        Object rawActiveWorkspace = Wire.required(object, "active_workspace");
        builder.activeWorkspace(rawActiveWorkspace == null ? null : Wire.uint64(rawActiveWorkspace, "SelectionChangedEvent.active_workspace"));
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "SelectionChangedEvent.screens", item -> SelectionScreen.fromWire(item)));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "SelectionChangedEvent.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "selection-changed");
        Wire.put(object, "active", active);
        Wire.put(object, "active_workspace", activeWorkspace);
        Wire.put(object, "screens", screens);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SelectionChangedEvent that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(activeWorkspace, that.activeWorkspace) && Objects.equals(screens, that.screens) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(active, activeWorkspace, screens, workspace); }

    @Override
    public String toString() { return "SelectionChangedEvent" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private UInt64 activeWorkspace;
        private boolean activeWorkspaceSet;
        private List<SelectionScreen> screens;
        private boolean screensSet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder active(boolean value) {
            this.active = value;
            this.activeSet = true;
            return this;
        }
        public Builder activeWorkspace(UInt64 value) {
            this.activeWorkspace = value;
            this.activeWorkspaceSet = true;
            return this;
        }
        public Builder screens(List<SelectionScreen> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public SelectionChangedEvent build() { return new SelectionChangedEvent(this); }
    }
}

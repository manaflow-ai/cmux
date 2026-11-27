// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TabGroupOutcome implements WireValue {
    /** Null when the command left no group. */
    private final TabGroupRecord group;
    private final UInt64 pane;
    /** Members in strip order. */
    private final List<UInt64> surfaces;
    /** The workspace of the group's pane. */
    private final UInt64 workspace;
    private final Map<String, Object> additionalProperties;

    private TabGroupOutcome(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = builder.group;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = builder.workspace;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public TabGroupRecord group() { return group; }
    public UInt64 pane() { return pane; }
    public List<UInt64> surfaces() { return surfaces; }
    public UInt64 workspace() { return workspace; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TabGroupOutcome fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TabGroupOutcome");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(rawGroup == null ? null : TabGroupRecord.fromWire(rawGroup));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "TabGroupOutcome.pane"));
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "TabGroupOutcome.surfaces", item -> Wire.uint64(item, "TabGroupOutcome.surfaces item")));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "TabGroupOutcome.workspace"));
        List<String> known = List.of("group", "pane", "surfaces", "workspace");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "pane", pane);
        Wire.put(object, "surfaces", surfaces);
        Wire.put(object, "workspace", workspace);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TabGroupOutcome that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(pane, that.pane) && Objects.equals(surfaces, that.surfaces) && Objects.equals(workspace, that.workspace) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(group, pane, surfaces, workspace, additionalProperties); }

    @Override
    public String toString() { return "TabGroupOutcome" + toWire(); }

    public static final class Builder {
        private TabGroupRecord group;
        private boolean groupSet;
        private UInt64 pane;
        private boolean paneSet;
        private List<UInt64> surfaces;
        private boolean surfacesSet;
        private UInt64 workspace;
        private boolean workspaceSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder group(TabGroupRecord value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder surfaces(List<UInt64> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TabGroupOutcome build() { return new TabGroupOutcome(this); }
    }
}

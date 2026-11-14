// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListWorkspacesKnown implements WireValue {
    private final Field<String> generation;
    private final Field<UInt64> paneRevision;
    private final Field<String> registryId;
    private final Field<UInt64> terminalRevision;
    private final Field<String> treeRevision;
    private final Field<UInt64> workspaceRevision;

    private ListWorkspacesKnown(Builder builder) {
        this.generation = builder.generation;
        this.paneRevision = builder.paneRevision;
        this.registryId = builder.registryId;
        this.terminalRevision = builder.terminalRevision;
        this.treeRevision = builder.treeRevision;
        this.workspaceRevision = builder.workspaceRevision;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> generation() { return generation; }
    public Field<UInt64> paneRevision() { return paneRevision; }
    public Field<String> registryId() { return registryId; }
    public Field<UInt64> terminalRevision() { return terminalRevision; }
    public Field<String> treeRevision() { return treeRevision; }
    public Field<UInt64> workspaceRevision() { return workspaceRevision; }

    public static ListWorkspacesKnown fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListWorkspacesKnown");
        Builder builder = builder();
        Object rawGeneration = Wire.optional(object, "generation");
        if (!Wire.isMissing(rawGeneration)) {
            builder.generation(rawGeneration == null ? null : Wire.string(rawGeneration, "ListWorkspacesKnown.generation"));
        }
        Object rawPaneRevision = Wire.optional(object, "pane_revision");
        if (!Wire.isMissing(rawPaneRevision)) {
            builder.paneRevision(rawPaneRevision == null ? null : Wire.uint64(rawPaneRevision, "ListWorkspacesKnown.pane_revision"));
        }
        Object rawRegistryId = Wire.optional(object, "registry_id");
        if (!Wire.isMissing(rawRegistryId)) {
            builder.registryId(rawRegistryId == null ? null : Wire.string(rawRegistryId, "ListWorkspacesKnown.registry_id"));
        }
        Object rawTerminalRevision = Wire.optional(object, "terminal_revision");
        if (!Wire.isMissing(rawTerminalRevision)) {
            builder.terminalRevision(rawTerminalRevision == null ? null : Wire.uint64(rawTerminalRevision, "ListWorkspacesKnown.terminal_revision"));
        }
        Object rawTreeRevision = Wire.optional(object, "tree_revision");
        if (!Wire.isMissing(rawTreeRevision)) {
            builder.treeRevision(rawTreeRevision == null ? null : Wire.string(rawTreeRevision, "ListWorkspacesKnown.tree_revision"));
        }
        Object rawWorkspaceRevision = Wire.optional(object, "workspace_revision");
        if (!Wire.isMissing(rawWorkspaceRevision)) {
            builder.workspaceRevision(rawWorkspaceRevision == null ? null : Wire.uint64(rawWorkspaceRevision, "ListWorkspacesKnown.workspace_revision"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "generation", generation);
        Wire.put(object, "pane_revision", paneRevision);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "tree_revision", treeRevision);
        Wire.put(object, "workspace_revision", workspaceRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListWorkspacesKnown that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(paneRevision, that.paneRevision) && Objects.equals(registryId, that.registryId) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(treeRevision, that.treeRevision) && Objects.equals(workspaceRevision, that.workspaceRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, paneRevision, registryId, terminalRevision, treeRevision, workspaceRevision); }

    @Override
    public String toString() { return "ListWorkspacesKnown" + toWire(); }

    public static final class Builder {
        private Field<String> generation = Field.omitted();
        private Field<UInt64> paneRevision = Field.omitted();
        private Field<String> registryId = Field.omitted();
        private Field<UInt64> terminalRevision = Field.omitted();
        private Field<String> treeRevision = Field.omitted();
        private Field<UInt64> workspaceRevision = Field.omitted();

        public Builder generation(String value) {
            this.generation = Field.ofNullable(value);
            return this;
        }
        public Builder paneRevision(UInt64 value) {
            this.paneRevision = Field.ofNullable(value);
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = Field.ofNullable(value);
            return this;
        }
        public Builder treeRevision(String value) {
            this.treeRevision = Field.ofNullable(value);
            return this;
        }
        public Builder workspaceRevision(UInt64 value) {
            this.workspaceRevision = Field.ofNullable(value);
            return this;
        }
        public ListWorkspacesKnown build() { return new ListWorkspacesKnown(this); }
    }
}

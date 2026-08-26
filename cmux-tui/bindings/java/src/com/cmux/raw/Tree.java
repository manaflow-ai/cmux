// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Tree implements WireValue {
    private final Field<String> generation;
    private final Field<UInt64> paneRevision;
    private final Field<String> registryId;
    private final Field<UInt64> terminalRevision;
    private final Field<UInt64> workspaceRevision;
    private final List<Workspace> workspaces;

    private Tree(Builder builder) {
        this.generation = builder.generation;
        this.paneRevision = builder.paneRevision;
        this.registryId = builder.registryId;
        this.terminalRevision = builder.terminalRevision;
        this.workspaceRevision = builder.workspaceRevision;
        if (!builder.workspacesSet) throw new IllegalArgumentException("workspaces is required");
        this.workspaces = List.copyOf(Wire.nonNull(builder.workspaces, "workspaces"));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> generation() { return generation; }
    public Field<UInt64> paneRevision() { return paneRevision; }
    public Field<String> registryId() { return registryId; }
    public Field<UInt64> terminalRevision() { return terminalRevision; }
    public Field<UInt64> workspaceRevision() { return workspaceRevision; }
    public List<Workspace> workspaces() { return workspaces; }

    public static Tree fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Tree");
        Builder builder = builder();
        Object rawGeneration = Wire.optional(object, "generation");
        if (!Wire.isMissing(rawGeneration)) {
            builder.generation(Wire.string(rawGeneration, "Tree.generation"));
        }
        Object rawPaneRevision = Wire.optional(object, "pane_revision");
        if (!Wire.isMissing(rawPaneRevision)) {
            builder.paneRevision(Wire.uint64(rawPaneRevision, "Tree.pane_revision"));
        }
        Object rawRegistryId = Wire.optional(object, "registry_id");
        if (!Wire.isMissing(rawRegistryId)) {
            builder.registryId(Wire.string(rawRegistryId, "Tree.registry_id"));
        }
        Object rawTerminalRevision = Wire.optional(object, "terminal_revision");
        if (!Wire.isMissing(rawTerminalRevision)) {
            builder.terminalRevision(Wire.uint64(rawTerminalRevision, "Tree.terminal_revision"));
        }
        Object rawWorkspaceRevision = Wire.optional(object, "workspace_revision");
        if (!Wire.isMissing(rawWorkspaceRevision)) {
            builder.workspaceRevision(Wire.uint64(rawWorkspaceRevision, "Tree.workspace_revision"));
        }
        Object rawWorkspaces = Wire.required(object, "workspaces");
        builder.workspaces(Wire.array(rawWorkspaces, "Tree.workspaces", item -> Workspace.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "generation", generation);
        Wire.put(object, "pane_revision", paneRevision);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "workspace_revision", workspaceRevision);
        Wire.put(object, "workspaces", workspaces);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Tree that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(paneRevision, that.paneRevision) && Objects.equals(registryId, that.registryId) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(workspaceRevision, that.workspaceRevision) && Objects.equals(workspaces, that.workspaces);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, paneRevision, registryId, terminalRevision, workspaceRevision, workspaces); }

    @Override
    public String toString() { return "Tree" + toWire(); }

    public static final class Builder {
        private Field<String> generation = Field.omitted();
        private Field<UInt64> paneRevision = Field.omitted();
        private Field<String> registryId = Field.omitted();
        private Field<UInt64> terminalRevision = Field.omitted();
        private Field<UInt64> workspaceRevision = Field.omitted();
        private List<Workspace> workspaces;
        private boolean workspacesSet;

        public Builder generation(String value) {
            this.generation = Field.of(value);
            return this;
        }
        public Builder paneRevision(UInt64 value) {
            this.paneRevision = Field.of(value);
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = Field.of(value);
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = Field.of(value);
            return this;
        }
        public Builder workspaceRevision(UInt64 value) {
            this.workspaceRevision = Field.of(value);
            return this;
        }
        public Builder workspaces(List<Workspace> value) {
            this.workspaces = value;
            this.workspacesSet = true;
            return this;
        }
        public Tree build() { return new Tree(this); }
    }
}

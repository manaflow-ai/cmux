// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Tree implements WireValue {
    private final Field<List<Workspace>> changed;
    private final Field<Boolean> delta;
    private final Field<String> epoch;
    private final Field<String> generation;
    /** The sidebar workspace groups. */
    private final Field<List<WorkspaceGroup>> groups;
    /** How many lines the connection had written when the tree was read: a later line may carry a change the tree lacks. */
    private final Field<UInt64> linesWrittenBeforeRead;
    private final Field<UInt64> next;
    private final Field<List<UInt64>> order;
    private final Field<UInt64> paneRevision;
    private final Field<String> registryId;
    private final Field<List<UInt64>> removed;
    /** Legacy inline saved groups accepted by tree readers; current daemons provide these through list-saved-tab-groups. */
    private final Field<List<SavedTabGroupRecord>> savedTabGroups;
    private final Field<UInt64> seq;
    private final Field<UInt64> terminalRevision;
    private final Field<UInt64> total;
    private final Field<String> treeRevision;
    private final Field<Boolean> unchanged;
    private final Field<UInt64> workspaceRevision;
    private final List<Workspace> workspaces;

    private Tree(Builder builder) {
        this.changed = builder.changed.map(value -> List.copyOf(value));
        this.delta = builder.delta;
        this.epoch = builder.epoch;
        this.generation = builder.generation;
        this.groups = builder.groups.map(value -> List.copyOf(value));
        this.linesWrittenBeforeRead = builder.linesWrittenBeforeRead;
        this.next = builder.next;
        this.order = builder.order.map(value -> List.copyOf(value));
        this.paneRevision = builder.paneRevision;
        this.registryId = builder.registryId;
        this.removed = builder.removed.map(value -> List.copyOf(value));
        this.savedTabGroups = builder.savedTabGroups.map(value -> List.copyOf(value));
        this.seq = builder.seq;
        this.terminalRevision = builder.terminalRevision;
        this.total = builder.total;
        this.treeRevision = builder.treeRevision;
        this.unchanged = builder.unchanged;
        this.workspaceRevision = builder.workspaceRevision;
        if (!builder.workspacesSet) throw new IllegalArgumentException("workspaces is required");
        this.workspaces = List.copyOf(Wire.nonNull(builder.workspaces, "workspaces"));
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<Workspace>> changed() { return changed; }
    public Field<Boolean> delta() { return delta; }
    public Field<String> epoch() { return epoch; }
    public Field<String> generation() { return generation; }
    public Field<List<WorkspaceGroup>> groups() { return groups; }
    public Field<UInt64> linesWrittenBeforeRead() { return linesWrittenBeforeRead; }
    public Field<UInt64> next() { return next; }
    public Field<List<UInt64>> order() { return order; }
    public Field<UInt64> paneRevision() { return paneRevision; }
    public Field<String> registryId() { return registryId; }
    public Field<List<UInt64>> removed() { return removed; }
    public Field<List<SavedTabGroupRecord>> savedTabGroups() { return savedTabGroups; }
    public Field<UInt64> seq() { return seq; }
    public Field<UInt64> terminalRevision() { return terminalRevision; }
    public Field<UInt64> total() { return total; }
    public Field<String> treeRevision() { return treeRevision; }
    public Field<Boolean> unchanged() { return unchanged; }
    public Field<UInt64> workspaceRevision() { return workspaceRevision; }
    public List<Workspace> workspaces() { return workspaces; }

    public static Tree fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Tree");
        Builder builder = builder();
        Object rawChanged = Wire.optional(object, "changed");
        if (!Wire.isMissing(rawChanged)) {
            builder.changed(Wire.array(rawChanged, "Tree.changed", item -> Workspace.fromWire(item)));
        }
        Object rawDelta = Wire.optional(object, "delta");
        if (!Wire.isMissing(rawDelta)) {
            builder.delta(Wire.bool(rawDelta, "Tree.delta"));
        }
        Object rawEpoch = Wire.optional(object, "epoch");
        if (!Wire.isMissing(rawEpoch)) {
            builder.epoch(Wire.string(rawEpoch, "Tree.epoch"));
        }
        Object rawGeneration = Wire.optional(object, "generation");
        if (!Wire.isMissing(rawGeneration)) {
            builder.generation(Wire.string(rawGeneration, "Tree.generation"));
        }
        Object rawGroups = Wire.optional(object, "groups");
        if (!Wire.isMissing(rawGroups)) {
            builder.groups(Wire.array(rawGroups, "Tree.groups", item -> WorkspaceGroup.fromWire(item)));
        }
        Object rawLinesWrittenBeforeRead = Wire.optional(object, "lines_written_before_read");
        if (!Wire.isMissing(rawLinesWrittenBeforeRead)) {
            builder.linesWrittenBeforeRead(Wire.uint64(rawLinesWrittenBeforeRead, "Tree.lines_written_before_read"));
        }
        Object rawNext = Wire.optional(object, "next");
        if (!Wire.isMissing(rawNext)) {
            builder.next(Wire.uint64(rawNext, "Tree.next"));
        }
        Object rawOrder = Wire.optional(object, "order");
        if (!Wire.isMissing(rawOrder)) {
            builder.order(Wire.array(rawOrder, "Tree.order", item -> Wire.uint64(item, "Tree.order item")));
        }
        Object rawPaneRevision = Wire.optional(object, "pane_revision");
        if (!Wire.isMissing(rawPaneRevision)) {
            builder.paneRevision(Wire.uint64(rawPaneRevision, "Tree.pane_revision"));
        }
        Object rawRegistryId = Wire.optional(object, "registry_id");
        if (!Wire.isMissing(rawRegistryId)) {
            builder.registryId(Wire.string(rawRegistryId, "Tree.registry_id"));
        }
        Object rawRemoved = Wire.optional(object, "removed");
        if (!Wire.isMissing(rawRemoved)) {
            builder.removed(Wire.array(rawRemoved, "Tree.removed", item -> Wire.uint64(item, "Tree.removed item")));
        }
        Object rawSavedTabGroups = Wire.optional(object, "saved_tab_groups");
        if (!Wire.isMissing(rawSavedTabGroups)) {
            builder.savedTabGroups(Wire.array(rawSavedTabGroups, "Tree.saved_tab_groups", item -> SavedTabGroupRecord.fromWire(item)));
        }
        Object rawSeq = Wire.optional(object, "seq");
        if (!Wire.isMissing(rawSeq)) {
            builder.seq(Wire.uint64(rawSeq, "Tree.seq"));
        }
        Object rawTerminalRevision = Wire.optional(object, "terminal_revision");
        if (!Wire.isMissing(rawTerminalRevision)) {
            builder.terminalRevision(Wire.uint64(rawTerminalRevision, "Tree.terminal_revision"));
        }
        Object rawTotal = Wire.optional(object, "total");
        if (!Wire.isMissing(rawTotal)) {
            builder.total(Wire.uint64(rawTotal, "Tree.total"));
        }
        Object rawTreeRevision = Wire.optional(object, "tree_revision");
        if (!Wire.isMissing(rawTreeRevision)) {
            builder.treeRevision(Wire.string(rawTreeRevision, "Tree.tree_revision"));
        }
        Object rawUnchanged = Wire.optional(object, "unchanged");
        if (!Wire.isMissing(rawUnchanged)) {
            builder.unchanged(Wire.bool(rawUnchanged, "Tree.unchanged"));
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
        Wire.put(object, "changed", changed);
        Wire.put(object, "delta", delta);
        Wire.put(object, "epoch", epoch);
        Wire.put(object, "generation", generation);
        Wire.put(object, "groups", groups);
        Wire.put(object, "lines_written_before_read", linesWrittenBeforeRead);
        Wire.put(object, "next", next);
        Wire.put(object, "order", order);
        Wire.put(object, "pane_revision", paneRevision);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "removed", removed);
        Wire.put(object, "saved_tab_groups", savedTabGroups);
        Wire.put(object, "seq", seq);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "total", total);
        Wire.put(object, "tree_revision", treeRevision);
        Wire.put(object, "unchanged", unchanged);
        Wire.put(object, "workspace_revision", workspaceRevision);
        Wire.put(object, "workspaces", workspaces);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Tree that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(delta, that.delta) && Objects.equals(epoch, that.epoch) && Objects.equals(generation, that.generation) && Objects.equals(groups, that.groups) && Objects.equals(linesWrittenBeforeRead, that.linesWrittenBeforeRead) && Objects.equals(next, that.next) && Objects.equals(order, that.order) && Objects.equals(paneRevision, that.paneRevision) && Objects.equals(registryId, that.registryId) && Objects.equals(removed, that.removed) && Objects.equals(savedTabGroups, that.savedTabGroups) && Objects.equals(seq, that.seq) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(total, that.total) && Objects.equals(treeRevision, that.treeRevision) && Objects.equals(unchanged, that.unchanged) && Objects.equals(workspaceRevision, that.workspaceRevision) && Objects.equals(workspaces, that.workspaces);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, delta, epoch, generation, groups, linesWrittenBeforeRead, next, order, paneRevision, registryId, removed, savedTabGroups, seq, terminalRevision, total, treeRevision, unchanged, workspaceRevision, workspaces); }

    @Override
    public String toString() { return "Tree" + toWire(); }

    public static final class Builder {
        private Field<List<Workspace>> changed = Field.omitted();
        private Field<Boolean> delta = Field.omitted();
        private Field<String> epoch = Field.omitted();
        private Field<String> generation = Field.omitted();
        private Field<List<WorkspaceGroup>> groups = Field.omitted();
        private Field<UInt64> linesWrittenBeforeRead = Field.omitted();
        private Field<UInt64> next = Field.omitted();
        private Field<List<UInt64>> order = Field.omitted();
        private Field<UInt64> paneRevision = Field.omitted();
        private Field<String> registryId = Field.omitted();
        private Field<List<UInt64>> removed = Field.omitted();
        private Field<List<SavedTabGroupRecord>> savedTabGroups = Field.omitted();
        private Field<UInt64> seq = Field.omitted();
        private Field<UInt64> terminalRevision = Field.omitted();
        private Field<UInt64> total = Field.omitted();
        private Field<String> treeRevision = Field.omitted();
        private Field<Boolean> unchanged = Field.omitted();
        private Field<UInt64> workspaceRevision = Field.omitted();
        private List<Workspace> workspaces;
        private boolean workspacesSet;

        public Builder changed(List<Workspace> value) {
            this.changed = Field.of(value);
            return this;
        }
        public Builder delta(Boolean value) {
            this.delta = Field.of(value);
            return this;
        }
        public Builder epoch(String value) {
            this.epoch = Field.of(value);
            return this;
        }
        public Builder generation(String value) {
            this.generation = Field.of(value);
            return this;
        }
        public Builder groups(List<WorkspaceGroup> value) {
            this.groups = Field.of(value);
            return this;
        }
        public Builder linesWrittenBeforeRead(UInt64 value) {
            this.linesWrittenBeforeRead = Field.of(value);
            return this;
        }
        public Builder next(UInt64 value) {
            this.next = Field.of(value);
            return this;
        }
        public Builder order(List<UInt64> value) {
            this.order = Field.of(value);
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
        public Builder removed(List<UInt64> value) {
            this.removed = Field.of(value);
            return this;
        }
        public Builder savedTabGroups(List<SavedTabGroupRecord> value) {
            this.savedTabGroups = Field.of(value);
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = Field.of(value);
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = Field.of(value);
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = Field.of(value);
            return this;
        }
        public Builder treeRevision(String value) {
            this.treeRevision = Field.of(value);
            return this;
        }
        public Builder unchanged(Boolean value) {
            this.unchanged = Field.of(value);
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

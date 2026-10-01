// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-group-to-new-workspace request. Protocol v12; authority: control. */
public final class MoveTabGroupToNewWorkspaceRequest implements WireValue {
    private final String group;
    private final Field<UInt64> index;
    private final Field<String> transaction;
    private final Field<String> workspaceGroup;

    private MoveTabGroupToNewWorkspaceRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.index = builder.index;
        this.transaction = builder.transaction;
        this.workspaceGroup = builder.workspaceGroup;
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public Field<UInt64> index() { return index; }
    public Field<String> transaction() { return transaction; }
    public Field<String> workspaceGroup() { return workspaceGroup; }

    public static MoveTabGroupToNewWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabGroupToNewWorkspaceRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "MoveTabGroupToNewWorkspaceRequest.group"));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "MoveTabGroupToNewWorkspaceRequest.index"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabGroupToNewWorkspaceRequest.transaction"));
        }
        Object rawWorkspaceGroup = Wire.optional(object, "workspace_group");
        if (!Wire.isMissing(rawWorkspaceGroup)) {
            builder.workspaceGroup(rawWorkspaceGroup == null ? null : Wire.string(rawWorkspaceGroup, "MoveTabGroupToNewWorkspaceRequest.workspace_group"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "workspace_group", workspaceGroup);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabGroupToNewWorkspaceRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(transaction, that.transaction) && Objects.equals(workspaceGroup, that.workspaceGroup);
    }

    @Override
    public int hashCode() { return Objects.hash(group, index, transaction, workspaceGroup); }

    @Override
    public String toString() { return "MoveTabGroupToNewWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private Field<UInt64> index = Field.omitted();
        private Field<String> transaction = Field.omitted();
        private Field<String> workspaceGroup = Field.omitted();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder workspaceGroup(String value) {
            this.workspaceGroup = Field.ofNullable(value);
            return this;
        }
        public MoveTabGroupToNewWorkspaceRequest build() { return new MoveTabGroupToNewWorkspaceRequest(this); }
    }
}

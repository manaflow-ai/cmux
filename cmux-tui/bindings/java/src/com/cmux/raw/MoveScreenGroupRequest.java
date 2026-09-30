// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-screen-group request. Protocol v12; authority: control. */
public final class MoveScreenGroupRequest implements WireValue {
    private final String group;
    private final Field<UInt64> index;
    private final Field<Boolean> newWorkspace;
    private final Field<UInt64> workspace;

    private MoveScreenGroupRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.index = builder.index;
        this.newWorkspace = builder.newWorkspace;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public Field<UInt64> index() { return index; }
    public Field<Boolean> newWorkspace() { return newWorkspace; }
    public Field<UInt64> workspace() { return workspace; }

    public static MoveScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveScreenGroupRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "MoveScreenGroupRequest.group"));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "MoveScreenGroupRequest.index"));
        }
        Object rawNewWorkspace = Wire.optional(object, "new_workspace");
        if (!Wire.isMissing(rawNewWorkspace)) {
            builder.newWorkspace(Wire.bool(rawNewWorkspace, "MoveScreenGroupRequest.new_workspace"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "MoveScreenGroupRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "new_workspace", newWorkspace);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveScreenGroupRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(newWorkspace, that.newWorkspace) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(group, index, newWorkspace, workspace); }

    @Override
    public String toString() { return "MoveScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private Field<UInt64> index = Field.omitted();
        private Field<Boolean> newWorkspace = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder newWorkspace(Boolean value) {
            this.newWorkspace = Field.of(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public MoveScreenGroupRequest build() { return new MoveScreenGroupRequest(this); }
    }
}

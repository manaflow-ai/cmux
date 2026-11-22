// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable update-workspace-group request. Protocol v12; authority: control. */
public final class UpdateWorkspaceGroupRequest implements WireValue {
    private final Field<Boolean> collapsed;
    private final Field<String> color;
    private final String group;
    private final Field<String> name;

    private UpdateWorkspaceGroupRequest(Builder builder) {
        this.collapsed = builder.collapsed;
        this.color = builder.color;
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.name = builder.name;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> collapsed() { return collapsed; }
    public Field<String> color() { return color; }
    public String group() { return group; }
    public Field<String> name() { return name; }

    public static UpdateWorkspaceGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UpdateWorkspaceGroupRequest");
        Builder builder = builder();
        Object rawCollapsed = Wire.optional(object, "collapsed");
        if (!Wire.isMissing(rawCollapsed)) {
            builder.collapsed(rawCollapsed == null ? null : Wire.bool(rawCollapsed, "UpdateWorkspaceGroupRequest.collapsed"));
        }
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "UpdateWorkspaceGroupRequest.color"));
        }
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "UpdateWorkspaceGroupRequest.group"));
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "UpdateWorkspaceGroupRequest.name"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "group", group);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UpdateWorkspaceGroupRequest that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(group, that.group) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, group, name); }

    @Override
    public String toString() { return "UpdateWorkspaceGroupRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> collapsed = Field.omitted();
        private Field<String> color = Field.omitted();
        private String group;
        private boolean groupSet;
        private Field<String> name = Field.omitted();

        public Builder collapsed(Boolean value) {
            this.collapsed = Field.ofNullable(value);
            return this;
        }
        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public UpdateWorkspaceGroupRequest build() { return new UpdateWorkspaceGroupRequest(this); }
    }
}

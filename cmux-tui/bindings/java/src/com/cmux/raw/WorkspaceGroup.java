// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class WorkspaceGroup implements WireValue {
    private final boolean collapsed;
    private final String color;
    /** workspace-group-icon-v1: the group's icon (one emoji, an SF Symbol name or a stored image), in list-personal's groups. */
    private final Field<String> icon;
    private final String id;
    private final UInt64 index;
    private final String name;
    /** workspace-group-pin-v1: a pinned group stays as an empty saved group when its workspaces close, in list-personal's groups. */
    private final Field<Boolean> pinned;
    /** profiles-v1: the room of a personal group, in list-personal's groups; list-workspaces leaves it out. */
    private final Field<String> profile;
    /** personal-mixed-order-v1: the personal workspace index the group shows right before, in list-personal's groups; null after every loose workspace. */
    private final Field<UInt64> topIndex;

    private WorkspaceGroup(Builder builder) {
        if (!builder.collapsedSet) throw new IllegalArgumentException("collapsed is required");
        this.collapsed = builder.collapsed;
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = builder.color;
        this.icon = builder.icon;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.pinned = builder.pinned;
        this.profile = builder.profile;
        this.topIndex = builder.topIndex;
    }

    public static Builder builder() { return new Builder(); }

    public boolean collapsed() { return collapsed; }
    public String color() { return color; }
    public Field<String> icon() { return icon; }
    public String id() { return id; }
    public UInt64 index() { return index; }
    public String name() { return name; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<String> profile() { return profile; }
    public Field<UInt64> topIndex() { return topIndex; }

    public static WorkspaceGroup fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspaceGroup");
        Builder builder = builder();
        Object rawCollapsed = Wire.required(object, "collapsed");
        builder.collapsed(Wire.bool(rawCollapsed, "WorkspaceGroup.collapsed"));
        Object rawColor = Wire.required(object, "color");
        builder.color(rawColor == null ? null : Wire.string(rawColor, "WorkspaceGroup.color"));
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "WorkspaceGroup.icon"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "WorkspaceGroup.id"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "WorkspaceGroup.index"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "WorkspaceGroup.name"));
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(Wire.bool(rawPinned, "WorkspaceGroup.pinned"));
        }
        Object rawProfile = Wire.optional(object, "profile");
        if (!Wire.isMissing(rawProfile)) {
            builder.profile(rawProfile == null ? null : Wire.string(rawProfile, "WorkspaceGroup.profile"));
        }
        Object rawTopIndex = Wire.optional(object, "top_index");
        if (!Wire.isMissing(rawTopIndex)) {
            builder.topIndex(rawTopIndex == null ? null : Wire.uint64(rawTopIndex, "WorkspaceGroup.top_index"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "icon", icon);
        Wire.put(object, "id", id);
        Wire.put(object, "index", index);
        Wire.put(object, "name", name);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "profile", profile);
        Wire.put(object, "top_index", topIndex);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WorkspaceGroup that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(icon, that.icon) && Objects.equals(id, that.id) && Objects.equals(index, that.index) && Objects.equals(name, that.name) && Objects.equals(pinned, that.pinned) && Objects.equals(profile, that.profile) && Objects.equals(topIndex, that.topIndex);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, icon, id, index, name, pinned, profile, topIndex); }

    @Override
    public String toString() { return "WorkspaceGroup" + toWire(); }

    public static final class Builder {
        private Boolean collapsed;
        private boolean collapsedSet;
        private String color;
        private boolean colorSet;
        private Field<String> icon = Field.omitted();
        private String id;
        private boolean idSet;
        private UInt64 index;
        private boolean indexSet;
        private String name;
        private boolean nameSet;
        private Field<Boolean> pinned = Field.omitted();
        private Field<String> profile = Field.omitted();
        private Field<UInt64> topIndex = Field.omitted();

        public Builder collapsed(boolean value) {
            this.collapsed = value;
            this.collapsedSet = true;
            return this;
        }
        public Builder color(String value) {
            this.color = value;
            this.colorSet = true;
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder pinned(Boolean value) {
            this.pinned = Field.of(value);
            return this;
        }
        public Builder profile(String value) {
            this.profile = Field.ofNullable(value);
            return this;
        }
        public Builder topIndex(UInt64 value) {
            this.topIndex = Field.ofNullable(value);
            return this;
        }
        public WorkspaceGroup build() { return new WorkspaceGroup(this); }
    }
}

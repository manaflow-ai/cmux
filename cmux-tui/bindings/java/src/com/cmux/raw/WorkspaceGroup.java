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
    private final String id;
    private final UInt64 index;
    private final String name;

    private WorkspaceGroup(Builder builder) {
        if (!builder.collapsedSet) throw new IllegalArgumentException("collapsed is required");
        this.collapsed = builder.collapsed;
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = builder.color;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
    }

    public static Builder builder() { return new Builder(); }

    public boolean collapsed() { return collapsed; }
    public String color() { return color; }
    public String id() { return id; }
    public UInt64 index() { return index; }
    public String name() { return name; }

    public static WorkspaceGroup fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspaceGroup");
        Builder builder = builder();
        Object rawCollapsed = Wire.required(object, "collapsed");
        builder.collapsed(Wire.bool(rawCollapsed, "WorkspaceGroup.collapsed"));
        Object rawColor = Wire.required(object, "color");
        builder.color(rawColor == null ? null : Wire.string(rawColor, "WorkspaceGroup.color"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "WorkspaceGroup.id"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "WorkspaceGroup.index"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "WorkspaceGroup.name"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "id", id);
        Wire.put(object, "index", index);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WorkspaceGroup that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(id, that.id) && Objects.equals(index, that.index) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, id, index, name); }

    @Override
    public String toString() { return "WorkspaceGroup" + toWire(); }

    public static final class Builder {
        private Boolean collapsed;
        private boolean collapsedSet;
        private String color;
        private boolean colorSet;
        private String id;
        private boolean idSet;
        private UInt64 index;
        private boolean indexSet;
        private String name;
        private boolean nameSet;

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
        public WorkspaceGroup build() { return new WorkspaceGroup(this); }
    }
}

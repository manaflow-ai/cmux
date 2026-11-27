// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ScreenGroupRun implements WireValue {
    private final boolean collapsed;
    private final String color;
    private final UInt64 count;
    private final Field<String> icon;
    private final String id;
    private final String name;
    private final String savedId;
    private final List<UInt64> screens;
    /** The index of the run's first screen. */
    private final UInt64 start;

    private ScreenGroupRun(Builder builder) {
        if (!builder.collapsedSet) throw new IllegalArgumentException("collapsed is required");
        this.collapsed = builder.collapsed;
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = Wire.nonNull(builder.color, "color");
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = Wire.nonNull(builder.count, "count");
        this.icon = builder.icon;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.savedIdSet) throw new IllegalArgumentException("saved_id is required");
        this.savedId = builder.savedId;
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = Wire.nonNull(builder.start, "start");
    }

    public static Builder builder() { return new Builder(); }

    public boolean collapsed() { return collapsed; }
    public String color() { return color; }
    public UInt64 count() { return count; }
    public Field<String> icon() { return icon; }
    public String id() { return id; }
    public String name() { return name; }
    public String savedId() { return savedId; }
    public List<UInt64> screens() { return screens; }
    public UInt64 start() { return start; }

    public static ScreenGroupRun fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScreenGroupRun");
        Builder builder = builder();
        Object rawCollapsed = Wire.required(object, "collapsed");
        builder.collapsed(Wire.bool(rawCollapsed, "ScreenGroupRun.collapsed"));
        Object rawColor = Wire.required(object, "color");
        builder.color(Wire.string(rawColor, "ScreenGroupRun.color"));
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint64(rawCount, "ScreenGroupRun.count"));
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "ScreenGroupRun.icon"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "ScreenGroupRun.id"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "ScreenGroupRun.name"));
        Object rawSavedId = Wire.required(object, "saved_id");
        builder.savedId(rawSavedId == null ? null : Wire.string(rawSavedId, "ScreenGroupRun.saved_id"));
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "ScreenGroupRun.screens", item -> Wire.uint64(item, "ScreenGroupRun.screens item")));
        Object rawStart = Wire.required(object, "start");
        builder.start(Wire.uint64(rawStart, "ScreenGroupRun.start"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "count", count);
        Wire.put(object, "icon", icon);
        Wire.put(object, "id", id);
        Wire.put(object, "name", name);
        Wire.put(object, "saved_id", savedId);
        Wire.put(object, "screens", screens);
        Wire.put(object, "start", start);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScreenGroupRun that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(count, that.count) && Objects.equals(icon, that.icon) && Objects.equals(id, that.id) && Objects.equals(name, that.name) && Objects.equals(savedId, that.savedId) && Objects.equals(screens, that.screens) && Objects.equals(start, that.start);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, count, icon, id, name, savedId, screens, start); }

    @Override
    public String toString() { return "ScreenGroupRun" + toWire(); }

    public static final class Builder {
        private Boolean collapsed;
        private boolean collapsedSet;
        private String color;
        private boolean colorSet;
        private UInt64 count;
        private boolean countSet;
        private Field<String> icon = Field.omitted();
        private String id;
        private boolean idSet;
        private String name;
        private boolean nameSet;
        private String savedId;
        private boolean savedIdSet;
        private List<UInt64> screens;
        private boolean screensSet;
        private UInt64 start;
        private boolean startSet;

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
        public Builder count(UInt64 value) {
            this.count = value;
            this.countSet = true;
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
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder savedId(String value) {
            this.savedId = value;
            this.savedIdSet = true;
            return this;
        }
        public Builder screens(List<UInt64> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public Builder start(UInt64 value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public ScreenGroupRun build() { return new ScreenGroupRun(this); }
    }
}

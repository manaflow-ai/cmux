// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TabGroupRun implements WireValue {
    private final boolean collapsed;
    /** Known values: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other values are future colors. */
    private final String color;
    private final UInt64 count;
    private final String id;
    private final String name;
    private final Field<UInt64> pane;
    private final String savedId;
    /** Strip index of the first member. */
    private final UInt64 start;
    private final List<UInt64> surfaces;
    private final Map<String, Object> additionalProperties;

    private TabGroupRun(Builder builder) {
        if (!builder.collapsedSet) throw new IllegalArgumentException("collapsed is required");
        this.collapsed = builder.collapsed;
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = Wire.nonNull(builder.color, "color");
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = Wire.nonNull(builder.count, "count");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.pane = builder.pane;
        if (!builder.savedIdSet) throw new IllegalArgumentException("saved_id is required");
        this.savedId = builder.savedId;
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = Wire.nonNull(builder.start, "start");
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public boolean collapsed() { return collapsed; }
    public String color() { return color; }
    public UInt64 count() { return count; }
    public String id() { return id; }
    public String name() { return name; }
    public Field<UInt64> pane() { return pane; }
    public String savedId() { return savedId; }
    public UInt64 start() { return start; }
    public List<UInt64> surfaces() { return surfaces; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TabGroupRun fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TabGroupRun");
        Builder builder = builder();
        Object rawCollapsed = Wire.required(object, "collapsed");
        builder.collapsed(Wire.bool(rawCollapsed, "TabGroupRun.collapsed"));
        Object rawColor = Wire.required(object, "color");
        builder.color(Wire.string(rawColor, "TabGroupRun.color"));
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint64(rawCount, "TabGroupRun.count"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "TabGroupRun.id"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "TabGroupRun.name"));
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(Wire.uint64(rawPane, "TabGroupRun.pane"));
        }
        Object rawSavedId = Wire.required(object, "saved_id");
        builder.savedId(rawSavedId == null ? null : Wire.string(rawSavedId, "TabGroupRun.saved_id"));
        Object rawStart = Wire.required(object, "start");
        builder.start(Wire.uint64(rawStart, "TabGroupRun.start"));
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "TabGroupRun.surfaces", item -> Wire.uint64(item, "TabGroupRun.surfaces item")));
        List<String> known = List.of("collapsed", "color", "count", "id", "name", "pane", "saved_id", "start", "surfaces");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "count", count);
        Wire.put(object, "id", id);
        Wire.put(object, "name", name);
        Wire.put(object, "pane", pane);
        Wire.put(object, "saved_id", savedId);
        Wire.put(object, "start", start);
        Wire.put(object, "surfaces", surfaces);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TabGroupRun that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(count, that.count) && Objects.equals(id, that.id) && Objects.equals(name, that.name) && Objects.equals(pane, that.pane) && Objects.equals(savedId, that.savedId) && Objects.equals(start, that.start) && Objects.equals(surfaces, that.surfaces) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, count, id, name, pane, savedId, start, surfaces, additionalProperties); }

    @Override
    public String toString() { return "TabGroupRun" + toWire(); }

    public static final class Builder {
        private Boolean collapsed;
        private boolean collapsedSet;
        private String color;
        private boolean colorSet;
        private UInt64 count;
        private boolean countSet;
        private String id;
        private boolean idSet;
        private String name;
        private boolean nameSet;
        private Field<UInt64> pane = Field.omitted();
        private String savedId;
        private boolean savedIdSet;
        private UInt64 start;
        private boolean startSet;
        private List<UInt64> surfaces;
        private boolean surfacesSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

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
        public Builder pane(UInt64 value) {
            this.pane = Field.of(value);
            return this;
        }
        public Builder savedId(String value) {
            this.savedId = value;
            this.savedIdSet = true;
            return this;
        }
        public Builder start(UInt64 value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public Builder surfaces(List<UInt64> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TabGroupRun build() { return new TabGroupRun(this); }
    }
}

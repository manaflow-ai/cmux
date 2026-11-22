// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TabGroupRecord implements WireValue {
    private final boolean collapsed;
    /** Known values: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other values are future colors. */
    private final String color;
    private final String id;
    /** May be empty: the group shows only its color. */
    private final String name;
    /** The linked saved group. */
    private final String savedId;
    private final Map<String, Object> additionalProperties;

    private TabGroupRecord(Builder builder) {
        if (!builder.collapsedSet) throw new IllegalArgumentException("collapsed is required");
        this.collapsed = builder.collapsed;
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = Wire.nonNull(builder.color, "color");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.savedIdSet) throw new IllegalArgumentException("saved_id is required");
        this.savedId = builder.savedId;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public boolean collapsed() { return collapsed; }
    public String color() { return color; }
    public String id() { return id; }
    public String name() { return name; }
    public String savedId() { return savedId; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TabGroupRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TabGroupRecord");
        Builder builder = builder();
        Object rawCollapsed = Wire.required(object, "collapsed");
        builder.collapsed(Wire.bool(rawCollapsed, "TabGroupRecord.collapsed"));
        Object rawColor = Wire.required(object, "color");
        builder.color(Wire.string(rawColor, "TabGroupRecord.color"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "TabGroupRecord.id"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "TabGroupRecord.name"));
        Object rawSavedId = Wire.required(object, "saved_id");
        builder.savedId(rawSavedId == null ? null : Wire.string(rawSavedId, "TabGroupRecord.saved_id"));
        List<String> known = List.of("collapsed", "color", "id", "name", "saved_id");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "id", id);
        Wire.put(object, "name", name);
        Wire.put(object, "saved_id", savedId);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TabGroupRecord that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(id, that.id) && Objects.equals(name, that.name) && Objects.equals(savedId, that.savedId) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, id, name, savedId, additionalProperties); }

    @Override
    public String toString() { return "TabGroupRecord" + toWire(); }

    public static final class Builder {
        private Boolean collapsed;
        private boolean collapsedSet;
        private String color;
        private boolean colorSet;
        private String id;
        private boolean idSet;
        private String name;
        private boolean nameSet;
        private String savedId;
        private boolean savedIdSet;
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
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TabGroupRecord build() { return new TabGroupRecord(this); }
    }
}

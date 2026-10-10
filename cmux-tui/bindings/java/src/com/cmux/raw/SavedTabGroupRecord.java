// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SavedTabGroupRecord implements WireValue {
    /** Known values: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other values are future colors. */
    private final String color;
    private final String id;
    private final List<SavedTabGroupMember> members;
    private final String name;
    /** The room whose bar shows the saved group (`default` for groups saved by these commands). */
    private final String room;
    private final UInt64 updatedAtMs;
    private final Map<String, Object> additionalProperties;

    private SavedTabGroupRecord(Builder builder) {
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = Wire.nonNull(builder.color, "color");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.membersSet) throw new IllegalArgumentException("members is required");
        this.members = List.copyOf(Wire.nonNull(builder.members, "members"));
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.roomSet) throw new IllegalArgumentException("room is required");
        this.room = Wire.nonNull(builder.room, "room");
        if (!builder.updatedAtMsSet) throw new IllegalArgumentException("updated_at_ms is required");
        this.updatedAtMs = Wire.nonNull(builder.updatedAtMs, "updated_at_ms");
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public String color() { return color; }
    public String id() { return id; }
    public List<SavedTabGroupMember> members() { return members; }
    public String name() { return name; }
    public String room() { return room; }
    public UInt64 updatedAtMs() { return updatedAtMs; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static SavedTabGroupRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SavedTabGroupRecord");
        Builder builder = builder();
        Object rawColor = Wire.required(object, "color");
        builder.color(Wire.string(rawColor, "SavedTabGroupRecord.color"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "SavedTabGroupRecord.id"));
        Object rawMembers = Wire.required(object, "members");
        builder.members(Wire.array(rawMembers, "SavedTabGroupRecord.members", item -> SavedTabGroupMember.fromWire(item)));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "SavedTabGroupRecord.name"));
        Object rawRoom = Wire.required(object, "room");
        builder.room(Wire.string(rawRoom, "SavedTabGroupRecord.room"));
        Object rawUpdatedAtMs = Wire.required(object, "updated_at_ms");
        builder.updatedAtMs(Wire.uint64(rawUpdatedAtMs, "SavedTabGroupRecord.updated_at_ms"));
        List<String> known = List.of("color", "id", "members", "name", "room", "updated_at_ms");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "color", color);
        Wire.put(object, "id", id);
        Wire.put(object, "members", members);
        Wire.put(object, "name", name);
        Wire.put(object, "room", room);
        Wire.put(object, "updated_at_ms", updatedAtMs);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SavedTabGroupRecord that)) return false;
        return Objects.equals(color, that.color) && Objects.equals(id, that.id) && Objects.equals(members, that.members) && Objects.equals(name, that.name) && Objects.equals(room, that.room) && Objects.equals(updatedAtMs, that.updatedAtMs) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(color, id, members, name, room, updatedAtMs, additionalProperties); }

    @Override
    public String toString() { return "SavedTabGroupRecord" + toWire(); }

    public static final class Builder {
        private String color;
        private boolean colorSet;
        private String id;
        private boolean idSet;
        private List<SavedTabGroupMember> members;
        private boolean membersSet;
        private String name;
        private boolean nameSet;
        private String room;
        private boolean roomSet;
        private UInt64 updatedAtMs;
        private boolean updatedAtMsSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

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
        public Builder members(List<SavedTabGroupMember> value) {
            this.members = value;
            this.membersSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder room(String value) {
            this.room = value;
            this.roomSet = true;
            return this;
        }
        public Builder updatedAtMs(UInt64 value) {
            this.updatedAtMs = value;
            this.updatedAtMsSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public SavedTabGroupRecord build() { return new SavedTabGroupRecord(this); }
    }
}

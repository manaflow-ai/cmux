// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Workspace implements WireValue {
    private final boolean active;
    private final UInt64 id;
    private final Field<String> key;
    private final String name;
    private final Field<String> nameRevision;
    private final Field<NameSource> nameSource;
    private final List<Screen> screens;
    private final Field<String> shortId;

    private Workspace(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        this.key = builder.key;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.nameRevision = builder.nameRevision;
        this.nameSource = builder.nameSource;
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
        this.shortId = builder.shortId;
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public UInt64 id() { return id; }
    public Field<String> key() { return key; }
    public String name() { return name; }
    public Field<String> nameRevision() { return nameRevision; }
    public Field<NameSource> nameSource() { return nameSource; }
    public List<Screen> screens() { return screens; }
    public Field<String> shortId() { return shortId; }

    public static Workspace fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Workspace");
        Builder builder = builder();
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "Workspace.active"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "Workspace.id"));
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(Wire.string(rawKey, "Workspace.key"));
        }
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "Workspace.name"));
        Object rawNameRevision = Wire.optional(object, "name_revision");
        if (!Wire.isMissing(rawNameRevision)) {
            builder.nameRevision(Wire.string(rawNameRevision, "Workspace.name_revision"));
        }
        Object rawNameSource = Wire.optional(object, "name_source");
        if (!Wire.isMissing(rawNameSource)) {
            builder.nameSource(NameSource.fromWire(rawNameSource));
        }
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "Workspace.screens", item -> Screen.fromWire(item)));
        Object rawShortId = Wire.optional(object, "short_id");
        if (!Wire.isMissing(rawShortId)) {
            builder.shortId(Wire.string(rawShortId, "Workspace.short_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "active", active);
        Wire.put(object, "id", id);
        Wire.put(object, "key", key);
        Wire.put(object, "name", name);
        Wire.put(object, "name_revision", nameRevision);
        Wire.put(object, "name_source", nameSource);
        Wire.put(object, "screens", screens);
        Wire.put(object, "short_id", shortId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Workspace that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(id, that.id) && Objects.equals(key, that.key) && Objects.equals(name, that.name) && Objects.equals(nameRevision, that.nameRevision) && Objects.equals(nameSource, that.nameSource) && Objects.equals(screens, that.screens) && Objects.equals(shortId, that.shortId);
    }

    @Override
    public int hashCode() { return Objects.hash(active, id, key, name, nameRevision, nameSource, screens, shortId); }

    @Override
    public String toString() { return "Workspace" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private UInt64 id;
        private boolean idSet;
        private Field<String> key = Field.omitted();
        private String name;
        private boolean nameSet;
        private Field<String> nameRevision = Field.omitted();
        private Field<NameSource> nameSource = Field.omitted();
        private List<Screen> screens;
        private boolean screensSet;
        private Field<String> shortId = Field.omitted();

        public Builder active(boolean value) {
            this.active = value;
            this.activeSet = true;
            return this;
        }
        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder key(String value) {
            this.key = Field.of(value);
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder nameRevision(String value) {
            this.nameRevision = Field.of(value);
            return this;
        }
        public Builder nameSource(NameSource value) {
            this.nameSource = Field.of(value);
            return this;
        }
        public Builder screens(List<Screen> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = Field.of(value);
            return this;
        }
        public Workspace build() { return new Workspace(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentUpdateHarness implements WireValue {
    private final String id;
    private final Field<String> latest;
    private final Field<String> name;
    private final Field<String> version;

    private AgentUpdateHarness(Builder builder) {
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        this.latest = builder.latest;
        this.name = builder.name;
        this.version = builder.version;
    }

    public static Builder builder() { return new Builder(); }

    public String id() { return id; }
    public Field<String> latest() { return latest; }
    public Field<String> name() { return name; }
    public Field<String> version() { return version; }

    public static AgentUpdateHarness fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentUpdateHarness");
        Builder builder = builder();
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "AgentUpdateHarness.id"));
        Object rawLatest = Wire.optional(object, "latest");
        if (!Wire.isMissing(rawLatest)) {
            builder.latest(Wire.string(rawLatest, "AgentUpdateHarness.latest"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(Wire.string(rawName, "AgentUpdateHarness.name"));
        }
        Object rawVersion = Wire.optional(object, "version");
        if (!Wire.isMissing(rawVersion)) {
            builder.version(Wire.string(rawVersion, "AgentUpdateHarness.version"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "id", id);
        Wire.put(object, "latest", latest);
        Wire.put(object, "name", name);
        Wire.put(object, "version", version);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentUpdateHarness that)) return false;
        return Objects.equals(id, that.id) && Objects.equals(latest, that.latest) && Objects.equals(name, that.name) && Objects.equals(version, that.version);
    }

    @Override
    public int hashCode() { return Objects.hash(id, latest, name, version); }

    @Override
    public String toString() { return "AgentUpdateHarness" + toWire(); }

    public static final class Builder {
        private String id;
        private boolean idSet;
        private Field<String> latest = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<String> version = Field.omitted();

        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder latest(String value) {
            this.latest = Field.of(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.of(value);
            return this;
        }
        public Builder version(String value) {
            this.version = Field.of(value);
            return this;
        }
        public AgentUpdateHarness build() { return new AgentUpdateHarness(this); }
    }
}

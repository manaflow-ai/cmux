// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CloudBootstrapResult implements WireValue {
    private final Object createdPath;
    private final Field<String> generation;
    private final Field<Boolean> occupied;
    private final Field<String> revision;

    private CloudBootstrapResult(Builder builder) {
        if (!builder.createdPathSet) throw new IllegalArgumentException("created_path is required");
        this.createdPath = builder.createdPath == null ? null : Wire.immutableJson(builder.createdPath);
        this.generation = builder.generation;
        this.occupied = builder.occupied;
        this.revision = builder.revision;
    }

    public static Builder builder() { return new Builder(); }

    public Object createdPath() { return createdPath; }
    public Field<String> generation() { return generation; }
    public Field<Boolean> occupied() { return occupied; }
    public Field<String> revision() { return revision; }

    public static CloudBootstrapResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudBootstrapResult");
        Builder builder = builder();
        Object rawCreatedPath = Wire.required(object, "created_path");
        builder.createdPath(rawCreatedPath == null ? null : Wire.immutableJson(rawCreatedPath));
        Object rawGeneration = Wire.optional(object, "generation");
        if (!Wire.isMissing(rawGeneration)) {
            builder.generation(rawGeneration == null ? null : Wire.string(rawGeneration, "CloudBootstrapResult.generation"));
        }
        Object rawOccupied = Wire.optional(object, "occupied");
        if (!Wire.isMissing(rawOccupied)) {
            builder.occupied(Wire.bool(rawOccupied, "CloudBootstrapResult.occupied"));
        }
        Object rawRevision = Wire.optional(object, "revision");
        if (!Wire.isMissing(rawRevision)) {
            builder.revision(rawRevision == null ? null : Wire.string(rawRevision, "CloudBootstrapResult.revision"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "created_path", createdPath);
        Wire.put(object, "generation", generation);
        Wire.put(object, "occupied", occupied);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudBootstrapResult that)) return false;
        return Objects.equals(createdPath, that.createdPath) && Objects.equals(generation, that.generation) && Objects.equals(occupied, that.occupied) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(createdPath, generation, occupied, revision); }

    @Override
    public String toString() { return "CloudBootstrapResult" + toWire(); }

    public static final class Builder {
        private Object createdPath;
        private boolean createdPathSet;
        private Field<String> generation = Field.omitted();
        private Field<Boolean> occupied = Field.omitted();
        private Field<String> revision = Field.omitted();

        public Builder createdPath(Object value) {
            this.createdPath = value;
            this.createdPathSet = true;
            return this;
        }
        public Builder generation(String value) {
            this.generation = Field.ofNullable(value);
            return this;
        }
        public Builder occupied(Boolean value) {
            this.occupied = Field.of(value);
            return this;
        }
        public Builder revision(String value) {
            this.revision = Field.ofNullable(value);
            return this;
        }
        public CloudBootstrapResult build() { return new CloudBootstrapResult(this); }
    }
}

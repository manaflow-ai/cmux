// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-workspace request. Protocol v7; authority: control. */
public final class CreateWorkspaceRequest implements WireValue {
    private final Field<String> current;
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    private final Field<String> key;
    private final Field<String> mutationId;
    private final Field<String> name;
    private final Field<String> origin;
    private final Field<String> placement;
    private final Field<Boolean> placesBySetting;

    private CreateWorkspaceRequest(Builder builder) {
        this.current = builder.current;
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.key = builder.key;
        this.mutationId = builder.mutationId;
        this.name = builder.name;
        this.origin = builder.origin;
        this.placement = builder.placement;
        this.placesBySetting = builder.placesBySetting;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> current() { return current; }
    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> key() { return key; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> name() { return name; }
    public Field<String> origin() { return origin; }
    public Field<String> placement() { return placement; }
    public Field<Boolean> placesBySetting() { return placesBySetting; }

    public static CreateWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateWorkspaceRequest");
        Builder builder = builder();
        Object rawCurrent = Wire.optional(object, "current");
        if (!Wire.isMissing(rawCurrent)) {
            builder.current(rawCurrent == null ? null : Wire.string(rawCurrent, "CreateWorkspaceRequest.current"));
        }
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "CreateWorkspaceRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "CreateWorkspaceRequest.expected_revision"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "CreateWorkspaceRequest.key"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "CreateWorkspaceRequest.mutation_id"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "CreateWorkspaceRequest.name"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CreateWorkspaceRequest.origin"));
        }
        Object rawPlacement = Wire.optional(object, "placement");
        if (!Wire.isMissing(rawPlacement)) {
            builder.placement(rawPlacement == null ? null : Wire.string(rawPlacement, "CreateWorkspaceRequest.placement"));
        }
        Object rawPlacesBySetting = Wire.optional(object, "places_by_setting");
        if (!Wire.isMissing(rawPlacesBySetting)) {
            builder.placesBySetting(Wire.bool(rawPlacesBySetting, "CreateWorkspaceRequest.places_by_setting"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "current", current);
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "key", key);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "name", name);
        Wire.put(object, "origin", origin);
        Wire.put(object, "placement", placement);
        Wire.put(object, "places_by_setting", placesBySetting);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateWorkspaceRequest that)) return false;
        return Objects.equals(current, that.current) && Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(key, that.key) && Objects.equals(mutationId, that.mutationId) && Objects.equals(name, that.name) && Objects.equals(origin, that.origin) && Objects.equals(placement, that.placement) && Objects.equals(placesBySetting, that.placesBySetting);
    }

    @Override
    public int hashCode() { return Objects.hash(current, expectedGeneration, expectedRevision, key, mutationId, name, origin, placement, placesBySetting); }

    @Override
    public String toString() { return "CreateWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private Field<String> current = Field.omitted();
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Field<String> placement = Field.omitted();
        private Field<Boolean> placesBySetting = Field.omitted();

        public Builder current(String value) {
            this.current = Field.ofNullable(value);
            return this;
        }
        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.ofNullable(value);
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder placement(String value) {
            this.placement = Field.ofNullable(value);
            return this;
        }
        public Builder placesBySetting(Boolean value) {
            this.placesBySetting = Field.of(value);
            return this;
        }
        public CreateWorkspaceRequest build() { return new CreateWorkspaceRequest(this); }
    }
}

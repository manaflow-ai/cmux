// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-tabs request. Protocol v12; authority: control. */
public final class CloseTabsRequest implements WireValue {
    private final Field<Boolean> endTerminals;
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final List<Object> surfaces;
    private final Field<String> transaction;

    private CloseTabsRequest(Builder builder) {
        this.endTerminals = builder.endTerminals;
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> endTerminals() { return endTerminals; }
    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public List<Object> surfaces() { return surfaces; }
    public Field<String> transaction() { return transaction; }

    public static CloseTabsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseTabsRequest");
        Builder builder = builder();
        Object rawEndTerminals = Wire.optional(object, "end_terminals");
        if (!Wire.isMissing(rawEndTerminals)) {
            builder.endTerminals(Wire.bool(rawEndTerminals, "CloseTabsRequest.end_terminals"));
        }
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "CloseTabsRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "CloseTabsRequest.expected_revision"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "CloseTabsRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CloseTabsRequest.origin"));
        }
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "CloseTabsRequest.surfaces", item -> Wire.immutableJson(item)));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "CloseTabsRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "end_terminals", endTerminals);
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "surfaces", surfaces);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseTabsRequest that)) return false;
        return Objects.equals(endTerminals, that.endTerminals) && Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(surfaces, that.surfaces) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(endTerminals, expectedGeneration, expectedRevision, mutationId, origin, surfaces, transaction); }

    @Override
    public String toString() { return "CloseTabsRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> endTerminals = Field.omitted();
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private List<Object> surfaces;
        private boolean surfacesSet;
        private Field<String> transaction = Field.omitted();

        public Builder endTerminals(Boolean value) {
            this.endTerminals = Field.of(value);
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
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder surfaces(List<Object> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public CloseTabsRequest build() { return new CloseTabsRequest(this); }
    }
}

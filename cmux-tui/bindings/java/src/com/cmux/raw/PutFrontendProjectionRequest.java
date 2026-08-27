// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable put-frontend-projection request. Protocol v7; authority: control. */
public final class PutFrontendProjectionRequest implements WireValue {
    /** Accepted by the current decoder but ignored for projection writes. */
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedProjectionRevision;
    /** Accepted by the current decoder but ignored for projection writes. */
    private final Field<UInt64> expectedRevision;
    private final String frontend;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final Object projection;
    private final long schemaVersion;
    private final String scope;
    private final String subjectKey;

    private PutFrontendProjectionRequest(Builder builder) {
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedProjectionRevision = builder.expectedProjectionRevision;
        this.expectedRevision = builder.expectedRevision;
        if (!builder.frontendSet) throw new IllegalArgumentException("frontend is required");
        this.frontend = Wire.nonNull(builder.frontend, "frontend");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.projectionSet) throw new IllegalArgumentException("projection is required");
        this.projection = builder.projection == null ? null : Wire.immutableJson(builder.projection);
        if (!builder.schemaVersionSet) throw new IllegalArgumentException("schema_version is required");
        this.schemaVersion = builder.schemaVersion;
        if (!builder.scopeSet) throw new IllegalArgumentException("scope is required");
        this.scope = Wire.nonNull(builder.scope, "scope");
        if (!builder.subjectKeySet) throw new IllegalArgumentException("subject_key is required");
        this.subjectKey = Wire.nonNull(builder.subjectKey, "subject_key");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedProjectionRevision() { return expectedProjectionRevision; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public String frontend() { return frontend; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public Object projection() { return projection; }
    public long schemaVersion() { return schemaVersion; }
    public String scope() { return scope; }
    public String subjectKey() { return subjectKey; }

    public static PutFrontendProjectionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PutFrontendProjectionRequest");
        Builder builder = builder();
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "PutFrontendProjectionRequest.expected_generation"));
        }
        Object rawExpectedProjectionRevision = Wire.optional(object, "expected_projection_revision");
        if (!Wire.isMissing(rawExpectedProjectionRevision)) {
            builder.expectedProjectionRevision(rawExpectedProjectionRevision == null ? null : Wire.uint64(rawExpectedProjectionRevision, "PutFrontendProjectionRequest.expected_projection_revision"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "PutFrontendProjectionRequest.expected_revision"));
        }
        Object rawFrontend = Wire.required(object, "frontend");
        builder.frontend(Wire.string(rawFrontend, "PutFrontendProjectionRequest.frontend"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "PutFrontendProjectionRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "PutFrontendProjectionRequest.origin"));
        }
        Object rawProjection = Wire.required(object, "projection");
        builder.projection(rawProjection == null ? null : Wire.immutableJson(rawProjection));
        Object rawSchemaVersion = Wire.required(object, "schema_version");
        builder.schemaVersion(Wire.uint32(rawSchemaVersion, "PutFrontendProjectionRequest.schema_version"));
        Object rawScope = Wire.required(object, "scope");
        builder.scope(Wire.string(rawScope, "PutFrontendProjectionRequest.scope"));
        Object rawSubjectKey = Wire.required(object, "subject_key");
        builder.subjectKey(Wire.string(rawSubjectKey, "PutFrontendProjectionRequest.subject_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_projection_revision", expectedProjectionRevision);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "frontend", frontend);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "projection", projection);
        Wire.put(object, "schema_version", schemaVersion);
        Wire.put(object, "scope", scope);
        Wire.put(object, "subject_key", subjectKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PutFrontendProjectionRequest that)) return false;
        return Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedProjectionRevision, that.expectedProjectionRevision) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(frontend, that.frontend) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(projection, that.projection) && Objects.equals(schemaVersion, that.schemaVersion) && Objects.equals(scope, that.scope) && Objects.equals(subjectKey, that.subjectKey);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedGeneration, expectedProjectionRevision, expectedRevision, frontend, mutationId, origin, projection, schemaVersion, scope, subjectKey); }

    @Override
    public String toString() { return "PutFrontendProjectionRequest" + toWire(); }

    public static final class Builder {
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedProjectionRevision = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private String frontend;
        private boolean frontendSet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Object projection;
        private boolean projectionSet;
        private Long schemaVersion;
        private boolean schemaVersionSet;
        private String scope;
        private boolean scopeSet;
        private String subjectKey;
        private boolean subjectKeySet;

        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedProjectionRevision(UInt64 value) {
            this.expectedProjectionRevision = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder frontend(String value) {
            this.frontend = value;
            this.frontendSet = true;
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
        public Builder projection(Object value) {
            this.projection = value;
            this.projectionSet = true;
            return this;
        }
        public Builder schemaVersion(long value) {
            this.schemaVersion = value;
            this.schemaVersionSet = true;
            return this;
        }
        public Builder scope(String value) {
            this.scope = value;
            this.scopeSet = true;
            return this;
        }
        public Builder subjectKey(String value) {
            this.subjectKey = value;
            this.subjectKeySet = true;
            return this;
        }
        public PutFrontendProjectionRequest build() { return new PutFrontendProjectionRequest(this); }
    }
}

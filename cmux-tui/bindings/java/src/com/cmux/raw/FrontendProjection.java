// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FrontendProjection implements WireValue {
    private final String frontend;
    private final Object projection;
    private final UInt64 projectionRevision;
    private final Field<Boolean> replayed;
    private final long schemaVersion;
    private final String scope;
    private final String subjectKey;

    private FrontendProjection(Builder builder) {
        if (!builder.frontendSet) throw new IllegalArgumentException("frontend is required");
        this.frontend = Wire.nonNull(builder.frontend, "frontend");
        if (!builder.projectionSet) throw new IllegalArgumentException("projection is required");
        this.projection = builder.projection == null ? null : Wire.immutableJson(builder.projection);
        if (!builder.projectionRevisionSet) throw new IllegalArgumentException("projection_revision is required");
        this.projectionRevision = Wire.nonNull(builder.projectionRevision, "projection_revision");
        this.replayed = builder.replayed;
        if (!builder.schemaVersionSet) throw new IllegalArgumentException("schema_version is required");
        this.schemaVersion = builder.schemaVersion;
        if (!builder.scopeSet) throw new IllegalArgumentException("scope is required");
        this.scope = Wire.nonNull(builder.scope, "scope");
        if (!builder.subjectKeySet) throw new IllegalArgumentException("subject_key is required");
        this.subjectKey = Wire.nonNull(builder.subjectKey, "subject_key");
    }

    public static Builder builder() { return new Builder(); }

    public String frontend() { return frontend; }
    public Object projection() { return projection; }
    public UInt64 projectionRevision() { return projectionRevision; }
    public Field<Boolean> replayed() { return replayed; }
    public long schemaVersion() { return schemaVersion; }
    public String scope() { return scope; }
    public String subjectKey() { return subjectKey; }

    public static FrontendProjection fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendProjection");
        Builder builder = builder();
        Object rawFrontend = Wire.required(object, "frontend");
        builder.frontend(Wire.string(rawFrontend, "FrontendProjection.frontend"));
        Object rawProjection = Wire.required(object, "projection");
        builder.projection(rawProjection == null ? null : Wire.immutableJson(rawProjection));
        Object rawProjectionRevision = Wire.required(object, "projection_revision");
        builder.projectionRevision(Wire.uint64(rawProjectionRevision, "FrontendProjection.projection_revision"));
        Object rawReplayed = Wire.optional(object, "replayed");
        if (!Wire.isMissing(rawReplayed)) {
            builder.replayed(Wire.bool(rawReplayed, "FrontendProjection.replayed"));
        }
        Object rawSchemaVersion = Wire.required(object, "schema_version");
        builder.schemaVersion(Wire.uint32(rawSchemaVersion, "FrontendProjection.schema_version"));
        Object rawScope = Wire.required(object, "scope");
        builder.scope(Wire.string(rawScope, "FrontendProjection.scope"));
        Object rawSubjectKey = Wire.required(object, "subject_key");
        builder.subjectKey(Wire.string(rawSubjectKey, "FrontendProjection.subject_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "frontend", frontend);
        Wire.put(object, "projection", projection);
        Wire.put(object, "projection_revision", projectionRevision);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "schema_version", schemaVersion);
        Wire.put(object, "scope", scope);
        Wire.put(object, "subject_key", subjectKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendProjection that)) return false;
        return Objects.equals(frontend, that.frontend) && Objects.equals(projection, that.projection) && Objects.equals(projectionRevision, that.projectionRevision) && Objects.equals(replayed, that.replayed) && Objects.equals(schemaVersion, that.schemaVersion) && Objects.equals(scope, that.scope) && Objects.equals(subjectKey, that.subjectKey);
    }

    @Override
    public int hashCode() { return Objects.hash(frontend, projection, projectionRevision, replayed, schemaVersion, scope, subjectKey); }

    @Override
    public String toString() { return "FrontendProjection" + toWire(); }

    public static final class Builder {
        private String frontend;
        private boolean frontendSet;
        private Object projection;
        private boolean projectionSet;
        private UInt64 projectionRevision;
        private boolean projectionRevisionSet;
        private Field<Boolean> replayed = Field.omitted();
        private Long schemaVersion;
        private boolean schemaVersionSet;
        private String scope;
        private boolean scopeSet;
        private String subjectKey;
        private boolean subjectKeySet;

        public Builder frontend(String value) {
            this.frontend = value;
            this.frontendSet = true;
            return this;
        }
        public Builder projection(Object value) {
            this.projection = value;
            this.projectionSet = true;
            return this;
        }
        public Builder projectionRevision(UInt64 value) {
            this.projectionRevision = value;
            this.projectionRevisionSet = true;
            return this;
        }
        public Builder replayed(Boolean value) {
            this.replayed = Field.of(value);
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
        public FrontendProjection build() { return new FrontendProjection(this); }
    }
}

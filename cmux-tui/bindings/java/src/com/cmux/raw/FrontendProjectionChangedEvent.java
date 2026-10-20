// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable frontend-projection-changed event. Protocol v7; streams: subscribe. */
public final class FrontendProjectionChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String frontend;
    private final String mutationId;
    private final String origin;
    private final UInt64 projectionRevision;
    private final String scope;
    private final String subjectKey;

    private FrontendProjectionChangedEvent(Builder builder) {
        if (!builder.frontendSet) throw new IllegalArgumentException("frontend is required");
        this.frontend = Wire.nonNull(builder.frontend, "frontend");
        if (!builder.mutationIdSet) throw new IllegalArgumentException("mutation_id is required");
        this.mutationId = Wire.nonNull(builder.mutationId, "mutation_id");
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        if (!builder.projectionRevisionSet) throw new IllegalArgumentException("projection_revision is required");
        this.projectionRevision = Wire.nonNull(builder.projectionRevision, "projection_revision");
        if (!builder.scopeSet) throw new IllegalArgumentException("scope is required");
        this.scope = Wire.nonNull(builder.scope, "scope");
        if (!builder.subjectKeySet) throw new IllegalArgumentException("subject_key is required");
        this.subjectKey = Wire.nonNull(builder.subjectKey, "subject_key");
    }

    public static Builder builder() { return new Builder(); }

    public String frontend() { return frontend; }
    public String mutationId() { return mutationId; }
    public String origin() { return origin; }
    public UInt64 projectionRevision() { return projectionRevision; }
    public String scope() { return scope; }
    public String subjectKey() { return subjectKey; }
    @Override public String event() { return "frontend-projection-changed"; }

    public static FrontendProjectionChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendProjectionChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "frontend-projection-changed", "FrontendProjectionChangedEvent.event");
        Object rawFrontend = Wire.required(object, "frontend");
        builder.frontend(Wire.string(rawFrontend, "FrontendProjectionChangedEvent.frontend"));
        Object rawMutationId = Wire.required(object, "mutation_id");
        builder.mutationId(Wire.string(rawMutationId, "FrontendProjectionChangedEvent.mutation_id"));
        Object rawOrigin = Wire.required(object, "origin");
        builder.origin(Wire.string(rawOrigin, "FrontendProjectionChangedEvent.origin"));
        Object rawProjectionRevision = Wire.required(object, "projection_revision");
        builder.projectionRevision(Wire.uint64(rawProjectionRevision, "FrontendProjectionChangedEvent.projection_revision"));
        Object rawScope = Wire.required(object, "scope");
        builder.scope(Wire.string(rawScope, "FrontendProjectionChangedEvent.scope"));
        Object rawSubjectKey = Wire.required(object, "subject_key");
        builder.subjectKey(Wire.string(rawSubjectKey, "FrontendProjectionChangedEvent.subject_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "frontend-projection-changed");
        Wire.put(object, "frontend", frontend);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "projection_revision", projectionRevision);
        Wire.put(object, "scope", scope);
        Wire.put(object, "subject_key", subjectKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendProjectionChangedEvent that)) return false;
        return Objects.equals(frontend, that.frontend) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(projectionRevision, that.projectionRevision) && Objects.equals(scope, that.scope) && Objects.equals(subjectKey, that.subjectKey);
    }

    @Override
    public int hashCode() { return Objects.hash(frontend, mutationId, origin, projectionRevision, scope, subjectKey); }

    @Override
    public String toString() { return "FrontendProjectionChangedEvent" + toWire(); }

    public static final class Builder {
        private String frontend;
        private boolean frontendSet;
        private String mutationId;
        private boolean mutationIdSet;
        private String origin;
        private boolean originSet;
        private UInt64 projectionRevision;
        private boolean projectionRevisionSet;
        private String scope;
        private boolean scopeSet;
        private String subjectKey;
        private boolean subjectKeySet;

        public Builder frontend(String value) {
            this.frontend = value;
            this.frontendSet = true;
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = value;
            this.mutationIdSet = true;
            return this;
        }
        public Builder origin(String value) {
            this.origin = value;
            this.originSet = true;
            return this;
        }
        public Builder projectionRevision(UInt64 value) {
            this.projectionRevision = value;
            this.projectionRevisionSet = true;
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
        public FrontendProjectionChangedEvent build() { return new FrontendProjectionChangedEvent(this); }
    }
}

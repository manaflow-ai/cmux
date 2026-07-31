// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable get-frontend-projection request. Protocol v7; authority: control. */
public final class GetFrontendProjectionRequest implements WireValue {
    private final String frontend;
    private final String scope;
    private final String subjectKey;

    private GetFrontendProjectionRequest(Builder builder) {
        if (!builder.frontendSet) throw new IllegalArgumentException("frontend is required");
        this.frontend = Wire.nonNull(builder.frontend, "frontend");
        if (!builder.scopeSet) throw new IllegalArgumentException("scope is required");
        this.scope = Wire.nonNull(builder.scope, "scope");
        if (!builder.subjectKeySet) throw new IllegalArgumentException("subject_key is required");
        this.subjectKey = Wire.nonNull(builder.subjectKey, "subject_key");
    }

    public static Builder builder() { return new Builder(); }

    public String frontend() { return frontend; }
    public String scope() { return scope; }
    public String subjectKey() { return subjectKey; }

    public static GetFrontendProjectionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetFrontendProjectionRequest");
        Builder builder = builder();
        Object rawFrontend = Wire.required(object, "frontend");
        builder.frontend(Wire.string(rawFrontend, "GetFrontendProjectionRequest.frontend"));
        Object rawScope = Wire.required(object, "scope");
        builder.scope(Wire.string(rawScope, "GetFrontendProjectionRequest.scope"));
        Object rawSubjectKey = Wire.required(object, "subject_key");
        builder.subjectKey(Wire.string(rawSubjectKey, "GetFrontendProjectionRequest.subject_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "frontend", frontend);
        Wire.put(object, "scope", scope);
        Wire.put(object, "subject_key", subjectKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetFrontendProjectionRequest that)) return false;
        return Objects.equals(frontend, that.frontend) && Objects.equals(scope, that.scope) && Objects.equals(subjectKey, that.subjectKey);
    }

    @Override
    public int hashCode() { return Objects.hash(frontend, scope, subjectKey); }

    @Override
    public String toString() { return "GetFrontendProjectionRequest" + toWire(); }

    public static final class Builder {
        private String frontend;
        private boolean frontendSet;
        private String scope;
        private boolean scopeSet;
        private String subjectKey;
        private boolean subjectKeySet;

        public Builder frontend(String value) {
            this.frontend = value;
            this.frontendSet = true;
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
        public GetFrontendProjectionRequest build() { return new GetFrontendProjectionRequest(this); }
    }
}

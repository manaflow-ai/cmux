// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable access-request-answer request. Protocol v12; authority: local-admin. */
public final class AccessRequestAnswerRequest implements WireValue {
    private final String outcome;
    private final Field<String> path;
    private final Field<String> reason;
    private final String requestId;
    private final Field<String> value;

    private AccessRequestAnswerRequest(Builder builder) {
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        this.path = builder.path;
        this.reason = builder.reason;
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        this.value = builder.value;
    }

    public static Builder builder() { return new Builder(); }

    public String outcome() { return outcome; }
    public Field<String> path() { return path; }
    public Field<String> reason() { return reason; }
    public String requestId() { return requestId; }
    public Field<String> value() { return value; }

    public static AccessRequestAnswerRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestAnswerRequest");
        Builder builder = builder();
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(Wire.string(rawOutcome, "AccessRequestAnswerRequest.outcome"));
        Object rawPath = Wire.optional(object, "path");
        if (!Wire.isMissing(rawPath)) {
            builder.path(rawPath == null ? null : Wire.string(rawPath, "AccessRequestAnswerRequest.path"));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : Wire.string(rawReason, "AccessRequestAnswerRequest.reason"));
        }
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "AccessRequestAnswerRequest.request_id"));
        Object rawValue = Wire.optional(object, "value");
        if (!Wire.isMissing(rawValue)) {
            builder.value(rawValue == null ? null : Wire.string(rawValue, "AccessRequestAnswerRequest.value"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "path", path);
        Wire.put(object, "reason", reason);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "value", value);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestAnswerRequest that)) return false;
        return Objects.equals(outcome, that.outcome) && Objects.equals(path, that.path) && Objects.equals(reason, that.reason) && Objects.equals(requestId, that.requestId) && Objects.equals(value, that.value);
    }

    @Override
    public int hashCode() { return Objects.hash(outcome, path, reason, requestId, value); }

    @Override
    public String toString() { return "AccessRequestAnswerRequest" + toWire(); }

    public static final class Builder {
        private String outcome;
        private boolean outcomeSet;
        private Field<String> path = Field.omitted();
        private Field<String> reason = Field.omitted();
        private String requestId;
        private boolean requestIdSet;
        private Field<String> value = Field.omitted();

        public Builder outcome(String value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = Field.ofNullable(value);
            return this;
        }
        public Builder reason(String value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public Builder value(String value) {
            this.value = Field.ofNullable(value);
            return this;
        }
        public AccessRequestAnswerRequest build() { return new AccessRequestAnswerRequest(this); }
    }
}

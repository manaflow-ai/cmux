// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetClientInfoResult implements WireValue {
    private final Field<Long> apiRevision;
    private final Field<String> apiVersion;

    private SetClientInfoResult(Builder builder) {
        this.apiRevision = builder.apiRevision;
        this.apiVersion = builder.apiVersion;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Long> apiRevision() { return apiRevision; }
    public Field<String> apiVersion() { return apiVersion; }

    public static SetClientInfoResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetClientInfoResult");
        Builder builder = builder();
        Object rawApiRevision = Wire.optional(object, "api_revision");
        if (!Wire.isMissing(rawApiRevision)) {
            builder.apiRevision(Wire.uint32(rawApiRevision, "SetClientInfoResult.api_revision"));
        }
        Object rawApiVersion = Wire.optional(object, "api_version");
        if (!Wire.isMissing(rawApiVersion)) {
            builder.apiVersion(Wire.string(rawApiVersion, "SetClientInfoResult.api_version"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "api_revision", apiRevision);
        Wire.put(object, "api_version", apiVersion);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetClientInfoResult that)) return false;
        return Objects.equals(apiRevision, that.apiRevision) && Objects.equals(apiVersion, that.apiVersion);
    }

    @Override
    public int hashCode() { return Objects.hash(apiRevision, apiVersion); }

    @Override
    public String toString() { return "SetClientInfoResult" + toWire(); }

    public static final class Builder {
        private Field<Long> apiRevision = Field.omitted();
        private Field<String> apiVersion = Field.omitted();

        public Builder apiRevision(Long value) {
            this.apiRevision = Field.of(value);
            return this;
        }
        public Builder apiVersion(String value) {
            this.apiVersion = Field.of(value);
            return this;
        }
        public SetClientInfoResult build() { return new SetClientInfoResult(this); }
    }
}

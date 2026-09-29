// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-bootstrap request. Protocol v12; authority: local-admin. */
public final class CloudBootstrapRequest implements WireValue {
    private final Field<Boolean> welcome;

    private CloudBootstrapRequest(Builder builder) {
        this.welcome = builder.welcome;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> welcome() { return welcome; }

    public static CloudBootstrapRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudBootstrapRequest");
        Builder builder = builder();
        Object rawWelcome = Wire.optional(object, "welcome");
        if (!Wire.isMissing(rawWelcome)) {
            builder.welcome(Wire.bool(rawWelcome, "CloudBootstrapRequest.welcome"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "welcome", welcome);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudBootstrapRequest that)) return false;
        return Objects.equals(welcome, that.welcome);
    }

    @Override
    public int hashCode() { return Objects.hash(welcome); }

    @Override
    public String toString() { return "CloudBootstrapRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> welcome = Field.omitted();

        public Builder welcome(Boolean value) {
            this.welcome = Field.of(value);
            return this;
        }
        public CloudBootstrapRequest build() { return new CloudBootstrapRequest(this); }
    }
}

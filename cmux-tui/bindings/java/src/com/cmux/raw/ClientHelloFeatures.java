// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientHelloFeatures implements WireValue {
    private final Field<String> hash;
    private final Map<String, Boolean> values;

    private ClientHelloFeatures(Builder builder) {
        this.hash = builder.hash;
        if (!builder.valuesSet) throw new IllegalArgumentException("values is required");
        this.values = Collections.unmodifiableMap(new LinkedHashMap<>(Wire.nonNull(builder.values, "values")));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> hash() { return hash; }
    public Map<String, Boolean> values() { return values; }

    public static ClientHelloFeatures fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientHelloFeatures");
        Builder builder = builder();
        Object rawHash = Wire.optional(object, "hash");
        if (!Wire.isMissing(rawHash)) {
            builder.hash(Wire.string(rawHash, "ClientHelloFeatures.hash"));
        }
        Object rawValues = Wire.required(object, "values");
        builder.values(Wire.map(rawValues, "ClientHelloFeatures.values", item -> Wire.bool(item, "ClientHelloFeatures.values value")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "hash", hash);
        Wire.put(object, "values", values);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientHelloFeatures that)) return false;
        return Objects.equals(hash, that.hash) && Objects.equals(values, that.values);
    }

    @Override
    public int hashCode() { return Objects.hash(hash, values); }

    @Override
    public String toString() { return "ClientHelloFeatures" + toWire(); }

    public static final class Builder {
        private Field<String> hash = Field.omitted();
        private Map<String, Boolean> values;
        private boolean valuesSet;

        public Builder hash(String value) {
            this.hash = Field.of(value);
            return this;
        }
        public Builder values(Map<String, Boolean> value) {
            this.values = value;
            this.valuesSet = true;
            return this;
        }
        public ClientHelloFeatures build() { return new ClientHelloFeatures(this); }
    }
}

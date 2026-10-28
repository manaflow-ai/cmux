// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable trace-start request. Protocol v12; authority: local-admin. */
public final class TraceStartRequest implements WireValue {
    private final Field<List<String>> categories;
    private final Field<Boolean> keys;
    private final Map<String, Object> additionalProperties;

    private TraceStartRequest(Builder builder) {
        this.categories = builder.categories.map(value -> List.copyOf(value));
        this.keys = builder.keys;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> categories() { return categories; }
    public Field<Boolean> keys() { return keys; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TraceStartRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TraceStartRequest");
        Builder builder = builder();
        Object rawCategories = Wire.optional(object, "categories");
        if (!Wire.isMissing(rawCategories)) {
            builder.categories(rawCategories == null ? null : Wire.array(rawCategories, "TraceStartRequest.categories", item -> Wire.string(item, "TraceStartRequest.categories item")));
        }
        Object rawKeys = Wire.optional(object, "keys");
        if (!Wire.isMissing(rawKeys)) {
            builder.keys(Wire.bool(rawKeys, "TraceStartRequest.keys"));
        }
        List<String> known = List.of("categories", "keys");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "categories", categories);
        Wire.put(object, "keys", keys);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TraceStartRequest that)) return false;
        return Objects.equals(categories, that.categories) && Objects.equals(keys, that.keys) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(categories, keys, additionalProperties); }

    @Override
    public String toString() { return "TraceStartRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> categories = Field.omitted();
        private Field<Boolean> keys = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder categories(List<String> value) {
            this.categories = Field.ofNullable(value);
            return this;
        }
        public Builder keys(Boolean value) {
            this.keys = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TraceStartRequest build() { return new TraceStartRequest(this); }
    }
}

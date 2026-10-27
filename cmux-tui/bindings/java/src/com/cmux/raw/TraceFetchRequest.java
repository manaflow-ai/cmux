// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable trace-fetch request. Protocol v12; authority: local-admin. */
public final class TraceFetchRequest implements WireValue {
    private final Field<UInt64> offset;
    private final Map<String, Object> additionalProperties;

    private TraceFetchRequest(Builder builder) {
        this.offset = builder.offset;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> offset() { return offset; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TraceFetchRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TraceFetchRequest");
        Builder builder = builder();
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(Wire.uint64(rawOffset, "TraceFetchRequest.offset"));
        }
        List<String> known = List.of("offset");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "offset", offset);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TraceFetchRequest that)) return false;
        return Objects.equals(offset, that.offset) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(offset, additionalProperties); }

    @Override
    public String toString() { return "TraceFetchRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> offset = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder offset(UInt64 value) {
            this.offset = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TraceFetchRequest build() { return new TraceFetchRequest(this); }
    }
}

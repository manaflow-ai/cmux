// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable chief-inspect request. Protocol v12; authority: local-admin. */
public final class ChiefInspectRequest implements WireValue {
    private final String path;
    private final Field<Map<String, String>> query;

    private ChiefInspectRequest(Builder builder) {
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        this.query = builder.query.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
    }

    public static Builder builder() { return new Builder(); }

    public String path() { return path; }
    public Field<Map<String, String>> query() { return query; }

    public static ChiefInspectRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefInspectRequest");
        Builder builder = builder();
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "ChiefInspectRequest.path"));
        Object rawQuery = Wire.optional(object, "query");
        if (!Wire.isMissing(rawQuery)) {
            builder.query(Wire.map(rawQuery, "ChiefInspectRequest.query", item -> Wire.string(item, "ChiefInspectRequest.query value")));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "path", path);
        Wire.put(object, "query", query);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefInspectRequest that)) return false;
        return Objects.equals(path, that.path) && Objects.equals(query, that.query);
    }

    @Override
    public int hashCode() { return Objects.hash(path, query); }

    @Override
    public String toString() { return "ChiefInspectRequest" + toWire(); }

    public static final class Builder {
        private String path;
        private boolean pathSet;
        private Field<Map<String, String>> query = Field.omitted();

        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder query(Map<String, String> value) {
            this.query = Field.of(value);
            return this;
        }
        public ChiefInspectRequest build() { return new ChiefInspectRequest(this); }
    }
}

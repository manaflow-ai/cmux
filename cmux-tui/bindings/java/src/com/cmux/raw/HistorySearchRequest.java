// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable history-search request. Protocol v12; authority: local-admin. */
public final class HistorySearchRequest implements WireValue {
    private final Field<List<String>> kinds;
    private final Field<Long> limit;
    private final String query;

    private HistorySearchRequest(Builder builder) {
        this.kinds = builder.kinds.map(value -> List.copyOf(value));
        this.limit = builder.limit;
        if (!builder.querySet) throw new IllegalArgumentException("query is required");
        this.query = Wire.nonNull(builder.query, "query");
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> kinds() { return kinds; }
    public Field<Long> limit() { return limit; }
    public String query() { return query; }

    public static HistorySearchRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HistorySearchRequest");
        Builder builder = builder();
        Object rawKinds = Wire.optional(object, "kinds");
        if (!Wire.isMissing(rawKinds)) {
            builder.kinds(Wire.array(rawKinds, "HistorySearchRequest.kinds", item -> Wire.string(item, "HistorySearchRequest.kinds item")));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "HistorySearchRequest.limit"));
        }
        Object rawQuery = Wire.required(object, "query");
        builder.query(Wire.string(rawQuery, "HistorySearchRequest.query"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "limit", limit);
        Wire.put(object, "query", query);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HistorySearchRequest that)) return false;
        return Objects.equals(kinds, that.kinds) && Objects.equals(limit, that.limit) && Objects.equals(query, that.query);
    }

    @Override
    public int hashCode() { return Objects.hash(kinds, limit, query); }

    @Override
    public String toString() { return "HistorySearchRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> kinds = Field.omitted();
        private Field<Long> limit = Field.omitted();
        private String query;
        private boolean querySet;

        public Builder kinds(List<String> value) {
            this.kinds = Field.of(value);
            return this;
        }
        public Builder limit(Long value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder query(String value) {
            this.query = value;
            this.querySet = true;
            return this;
        }
        public HistorySearchRequest build() { return new HistorySearchRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-search request. Protocol v12; authority: local-admin. */
public final class ConversationSearchRequest implements WireValue {
    private final long limit;
    private final String query;

    private ConversationSearchRequest(Builder builder) {
        if (!builder.limitSet) throw new IllegalArgumentException("limit is required");
        this.limit = builder.limit;
        if (!builder.querySet) throw new IllegalArgumentException("query is required");
        this.query = Wire.nonNull(builder.query, "query");
    }

    public static Builder builder() { return new Builder(); }

    public long limit() { return limit; }
    public String query() { return query; }

    public static ConversationSearchRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationSearchRequest");
        Builder builder = builder();
        Object rawLimit = Wire.required(object, "limit");
        builder.limit(Wire.uint32(rawLimit, "ConversationSearchRequest.limit"));
        Object rawQuery = Wire.required(object, "query");
        builder.query(Wire.string(rawQuery, "ConversationSearchRequest.query"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "limit", limit);
        Wire.put(object, "query", query);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationSearchRequest that)) return false;
        return Objects.equals(limit, that.limit) && Objects.equals(query, that.query);
    }

    @Override
    public int hashCode() { return Objects.hash(limit, query); }

    @Override
    public String toString() { return "ConversationSearchRequest" + toWire(); }

    public static final class Builder {
        private Long limit;
        private boolean limitSet;
        private String query;
        private boolean querySet;

        public Builder limit(long value) {
            this.limit = value;
            this.limitSet = true;
            return this;
        }
        public Builder query(String value) {
            this.query = value;
            this.querySet = true;
            return this;
        }
        public ConversationSearchRequest build() { return new ConversationSearchRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-notifications request. Protocol v12; authority: control. */
public final class ListNotificationsRequest implements WireValue {
    private final Field<UInt64> limit;
    private final Field<String> since;

    private ListNotificationsRequest(Builder builder) {
        this.limit = builder.limit;
        this.since = builder.since;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> limit() { return limit; }
    public Field<String> since() { return since; }

    public static ListNotificationsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListNotificationsRequest");
        Builder builder = builder();
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint64(rawLimit, "ListNotificationsRequest.limit"));
        }
        Object rawSince = Wire.optional(object, "since");
        if (!Wire.isMissing(rawSince)) {
            builder.since(rawSince == null ? null : Wire.string(rawSince, "ListNotificationsRequest.since"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "limit", limit);
        Wire.put(object, "since", since);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListNotificationsRequest that)) return false;
        return Objects.equals(limit, that.limit) && Objects.equals(since, that.since);
    }

    @Override
    public int hashCode() { return Objects.hash(limit, since); }

    @Override
    public String toString() { return "ListNotificationsRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> limit = Field.omitted();
        private Field<String> since = Field.omitted();

        public Builder limit(UInt64 value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder since(String value) {
            this.since = Field.ofNullable(value);
            return this;
        }
        public ListNotificationsRequest build() { return new ListNotificationsRequest(this); }
    }
}

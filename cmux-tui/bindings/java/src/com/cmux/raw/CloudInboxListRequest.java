// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-inbox-list request. Protocol v12; authority: local-admin. */
public final class CloudInboxListRequest implements WireValue {
    private final Field<Boolean> includeArchived;
    private final Field<Long> limit;

    private CloudInboxListRequest(Builder builder) {
        this.includeArchived = builder.includeArchived;
        this.limit = builder.limit;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> includeArchived() { return includeArchived; }
    public Field<Long> limit() { return limit; }

    public static CloudInboxListRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudInboxListRequest");
        Builder builder = builder();
        Object rawIncludeArchived = Wire.optional(object, "include_archived");
        if (!Wire.isMissing(rawIncludeArchived)) {
            builder.includeArchived(Wire.bool(rawIncludeArchived, "CloudInboxListRequest.include_archived"));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "CloudInboxListRequest.limit"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "include_archived", includeArchived);
        Wire.put(object, "limit", limit);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudInboxListRequest that)) return false;
        return Objects.equals(includeArchived, that.includeArchived) && Objects.equals(limit, that.limit);
    }

    @Override
    public int hashCode() { return Objects.hash(includeArchived, limit); }

    @Override
    public String toString() { return "CloudInboxListRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> includeArchived = Field.omitted();
        private Field<Long> limit = Field.omitted();

        public Builder includeArchived(Boolean value) {
            this.includeArchived = Field.of(value);
            return this;
        }
        public Builder limit(Long value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public CloudInboxListRequest build() { return new CloudInboxListRequest(this); }
    }
}

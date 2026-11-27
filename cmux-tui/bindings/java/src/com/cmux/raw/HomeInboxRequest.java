// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable home-inbox request. Protocol v12; authority: local-admin. */
public final class HomeInboxRequest implements WireValue {
    private final Field<List<String>> ids;
    private final Field<UInt64> limit;
    private final Field<UInt64> offset;
    private final Field<List<String>> owners;
    private final Field<String> scope;
    private final Field<UInt64> since;

    private HomeInboxRequest(Builder builder) {
        this.ids = builder.ids.map(value -> List.copyOf(value));
        this.limit = builder.limit;
        this.offset = builder.offset;
        this.owners = builder.owners.map(value -> List.copyOf(value));
        this.scope = builder.scope;
        this.since = builder.since;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> ids() { return ids; }
    public Field<UInt64> limit() { return limit; }
    public Field<UInt64> offset() { return offset; }
    public Field<List<String>> owners() { return owners; }
    public Field<String> scope() { return scope; }
    public Field<UInt64> since() { return since; }

    public static HomeInboxRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeInboxRequest");
        Builder builder = builder();
        Object rawIds = Wire.optional(object, "ids");
        if (!Wire.isMissing(rawIds)) {
            builder.ids(rawIds == null ? null : Wire.array(rawIds, "HomeInboxRequest.ids", item -> Wire.string(item, "HomeInboxRequest.ids item")));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint64(rawLimit, "HomeInboxRequest.limit"));
        }
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(rawOffset == null ? null : Wire.uint64(rawOffset, "HomeInboxRequest.offset"));
        }
        Object rawOwners = Wire.optional(object, "owners");
        if (!Wire.isMissing(rawOwners)) {
            builder.owners(rawOwners == null ? null : Wire.array(rawOwners, "HomeInboxRequest.owners", item -> Wire.string(item, "HomeInboxRequest.owners item")));
        }
        Object rawScope = Wire.optional(object, "scope");
        if (!Wire.isMissing(rawScope)) {
            builder.scope(rawScope == null ? null : Wire.string(rawScope, "HomeInboxRequest.scope"));
        }
        Object rawSince = Wire.optional(object, "since");
        if (!Wire.isMissing(rawSince)) {
            builder.since(rawSince == null ? null : Wire.uint64(rawSince, "HomeInboxRequest.since"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ids", ids);
        Wire.put(object, "limit", limit);
        Wire.put(object, "offset", offset);
        Wire.put(object, "owners", owners);
        Wire.put(object, "scope", scope);
        Wire.put(object, "since", since);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeInboxRequest that)) return false;
        return Objects.equals(ids, that.ids) && Objects.equals(limit, that.limit) && Objects.equals(offset, that.offset) && Objects.equals(owners, that.owners) && Objects.equals(scope, that.scope) && Objects.equals(since, that.since);
    }

    @Override
    public int hashCode() { return Objects.hash(ids, limit, offset, owners, scope, since); }

    @Override
    public String toString() { return "HomeInboxRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> ids = Field.omitted();
        private Field<UInt64> limit = Field.omitted();
        private Field<UInt64> offset = Field.omitted();
        private Field<List<String>> owners = Field.omitted();
        private Field<String> scope = Field.omitted();
        private Field<UInt64> since = Field.omitted();

        public Builder ids(List<String> value) {
            this.ids = Field.ofNullable(value);
            return this;
        }
        public Builder limit(UInt64 value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = Field.ofNullable(value);
            return this;
        }
        public Builder owners(List<String> value) {
            this.owners = Field.ofNullable(value);
            return this;
        }
        public Builder scope(String value) {
            this.scope = Field.ofNullable(value);
            return this;
        }
        public Builder since(UInt64 value) {
            this.since = Field.ofNullable(value);
            return this;
        }
        public HomeInboxRequest build() { return new HomeInboxRequest(this); }
    }
}

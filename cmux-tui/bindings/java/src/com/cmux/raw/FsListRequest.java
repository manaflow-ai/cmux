// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable fs.list request. Protocol v12; authority: control. */
public final class FsListRequest implements WireValue {
    private final Field<String> cursor;
    private final Field<FsFilter> filter;
    private final Field<UInt64> limit;
    private final Field<String> listing;
    private final Field<String> path;
    private final Field<FsSort> sort;

    private FsListRequest(Builder builder) {
        this.cursor = builder.cursor;
        this.filter = builder.filter;
        this.limit = builder.limit;
        this.listing = builder.listing;
        this.path = builder.path;
        this.sort = builder.sort;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> cursor() { return cursor; }
    public Field<FsFilter> filter() { return filter; }
    public Field<UInt64> limit() { return limit; }
    public Field<String> listing() { return listing; }
    public Field<String> path() { return path; }
    public Field<FsSort> sort() { return sort; }

    public static FsListRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsListRequest");
        Builder builder = builder();
        Object rawCursor = Wire.optional(object, "cursor");
        if (!Wire.isMissing(rawCursor)) {
            builder.cursor(rawCursor == null ? null : Wire.string(rawCursor, "FsListRequest.cursor"));
        }
        Object rawFilter = Wire.optional(object, "filter");
        if (!Wire.isMissing(rawFilter)) {
            builder.filter(FsFilter.fromWire(rawFilter));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(Wire.uint64(rawLimit, "FsListRequest.limit"));
        }
        Object rawListing = Wire.optional(object, "listing");
        if (!Wire.isMissing(rawListing)) {
            builder.listing(rawListing == null ? null : Wire.string(rawListing, "FsListRequest.listing"));
        }
        Object rawPath = Wire.optional(object, "path");
        if (!Wire.isMissing(rawPath)) {
            builder.path(rawPath == null ? null : Wire.string(rawPath, "FsListRequest.path"));
        }
        Object rawSort = Wire.optional(object, "sort");
        if (!Wire.isMissing(rawSort)) {
            builder.sort(FsSort.fromWire(rawSort));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "filter", filter);
        Wire.put(object, "limit", limit);
        Wire.put(object, "listing", listing);
        Wire.put(object, "path", path);
        Wire.put(object, "sort", sort);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsListRequest that)) return false;
        return Objects.equals(cursor, that.cursor) && Objects.equals(filter, that.filter) && Objects.equals(limit, that.limit) && Objects.equals(listing, that.listing) && Objects.equals(path, that.path) && Objects.equals(sort, that.sort);
    }

    @Override
    public int hashCode() { return Objects.hash(cursor, filter, limit, listing, path, sort); }

    @Override
    public String toString() { return "FsListRequest" + toWire(); }

    public static final class Builder {
        private Field<String> cursor = Field.omitted();
        private Field<FsFilter> filter = Field.omitted();
        private Field<UInt64> limit = Field.omitted();
        private Field<String> listing = Field.omitted();
        private Field<String> path = Field.omitted();
        private Field<FsSort> sort = Field.omitted();

        public Builder cursor(String value) {
            this.cursor = Field.ofNullable(value);
            return this;
        }
        public Builder filter(FsFilter value) {
            this.filter = Field.of(value);
            return this;
        }
        public Builder limit(UInt64 value) {
            this.limit = Field.of(value);
            return this;
        }
        public Builder listing(String value) {
            this.listing = Field.ofNullable(value);
            return this;
        }
        public Builder path(String value) {
            this.path = Field.ofNullable(value);
            return this;
        }
        public Builder sort(FsSort value) {
            this.sort = Field.of(value);
            return this;
        }
        public FsListRequest build() { return new FsListRequest(this); }
    }
}

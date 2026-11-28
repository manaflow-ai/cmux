// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-workspaces request. Protocol v5; authority: control. */
public final class ListWorkspacesRequest implements WireValue {
    private final Field<UInt64> after;
    private final Field<ListWorkspacesKnown> known;
    private final Field<UInt64> limit;
    private final Field<String> rows;
    private final Field<ListWorkspacesSince> since;

    private ListWorkspacesRequest(Builder builder) {
        this.after = builder.after;
        this.known = builder.known;
        this.limit = builder.limit;
        this.rows = builder.rows;
        this.since = builder.since;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> after() { return after; }
    public Field<ListWorkspacesKnown> known() { return known; }
    public Field<UInt64> limit() { return limit; }
    public Field<String> rows() { return rows; }
    public Field<ListWorkspacesSince> since() { return since; }

    public static ListWorkspacesRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListWorkspacesRequest");
        Builder builder = builder();
        Object rawAfter = Wire.optional(object, "after");
        if (!Wire.isMissing(rawAfter)) {
            builder.after(rawAfter == null ? null : Wire.uint64(rawAfter, "ListWorkspacesRequest.after"));
        }
        Object rawKnown = Wire.optional(object, "known");
        if (!Wire.isMissing(rawKnown)) {
            builder.known(rawKnown == null ? null : ListWorkspacesKnown.fromWire(rawKnown));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint64(rawLimit, "ListWorkspacesRequest.limit"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.string(rawRows, "ListWorkspacesRequest.rows"));
        }
        Object rawSince = Wire.optional(object, "since");
        if (!Wire.isMissing(rawSince)) {
            builder.since(rawSince == null ? null : ListWorkspacesSince.fromWire(rawSince));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after", after);
        Wire.put(object, "known", known);
        Wire.put(object, "limit", limit);
        Wire.put(object, "rows", rows);
        Wire.put(object, "since", since);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListWorkspacesRequest that)) return false;
        return Objects.equals(after, that.after) && Objects.equals(known, that.known) && Objects.equals(limit, that.limit) && Objects.equals(rows, that.rows) && Objects.equals(since, that.since);
    }

    @Override
    public int hashCode() { return Objects.hash(after, known, limit, rows, since); }

    @Override
    public String toString() { return "ListWorkspacesRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> after = Field.omitted();
        private Field<ListWorkspacesKnown> known = Field.omitted();
        private Field<UInt64> limit = Field.omitted();
        private Field<String> rows = Field.omitted();
        private Field<ListWorkspacesSince> since = Field.omitted();

        public Builder after(UInt64 value) {
            this.after = Field.ofNullable(value);
            return this;
        }
        public Builder known(ListWorkspacesKnown value) {
            this.known = Field.ofNullable(value);
            return this;
        }
        public Builder limit(UInt64 value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder rows(String value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder since(ListWorkspacesSince value) {
            this.since = Field.ofNullable(value);
            return this;
        }
        public ListWorkspacesRequest build() { return new ListWorkspacesRequest(this); }
    }
}

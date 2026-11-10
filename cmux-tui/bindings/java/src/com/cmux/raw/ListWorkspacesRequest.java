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
    private final Field<ListWorkspacesKnown> known;

    private ListWorkspacesRequest(Builder builder) {
        this.known = builder.known;
    }

    public static Builder builder() { return new Builder(); }

    public Field<ListWorkspacesKnown> known() { return known; }

    public static ListWorkspacesRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListWorkspacesRequest");
        Builder builder = builder();
        Object rawKnown = Wire.optional(object, "known");
        if (!Wire.isMissing(rawKnown)) {
            builder.known(rawKnown == null ? null : ListWorkspacesKnown.fromWire(rawKnown));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "known", known);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListWorkspacesRequest that)) return false;
        return Objects.equals(known, that.known);
    }

    @Override
    public int hashCode() { return Objects.hash(known); }

    @Override
    public String toString() { return "ListWorkspacesRequest" + toWire(); }

    public static final class Builder {
        private Field<ListWorkspacesKnown> known = Field.omitted();

        public Builder known(ListWorkspacesKnown value) {
            this.known = Field.ofNullable(value);
            return this;
        }
        public ListWorkspacesRequest build() { return new ListWorkspacesRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-tab-groups request. Protocol v12; authority: control. */
public final class ListTabGroupsRequest implements WireValue {

    private ListTabGroupsRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static ListTabGroupsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListTabGroupsRequest");
        Builder builder = builder();
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListTabGroupsRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "ListTabGroupsRequest" + toWire(); }

    public static final class Builder {

        public ListTabGroupsRequest build() { return new ListTabGroupsRequest(this); }
    }
}

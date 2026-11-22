// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-saved-screen-groups request. Protocol v12; authority: control. */
public final class ListSavedScreenGroupsRequest implements WireValue {

    private ListSavedScreenGroupsRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static ListSavedScreenGroupsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListSavedScreenGroupsRequest");
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
        if (!(other instanceof ListSavedScreenGroupsRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "ListSavedScreenGroupsRequest" + toWire(); }

    public static final class Builder {

        public ListSavedScreenGroupsRequest build() { return new ListSavedScreenGroupsRequest(this); }
    }
}

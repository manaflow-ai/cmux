// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable park-tabs request. Protocol v12; authority: control. */
public final class ParkTabsRequest implements WireValue {
    private final List<Object> surfaces;

    private ParkTabsRequest(Builder builder) {
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
    }

    public static Builder builder() { return new Builder(); }

    public List<Object> surfaces() { return surfaces; }

    public static ParkTabsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ParkTabsRequest");
        Builder builder = builder();
        Object rawSurfaces = Wire.required(object, "surfaces", "tabs");
        builder.surfaces(Wire.array(rawSurfaces, "ParkTabsRequest.surfaces", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surfaces", surfaces);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ParkTabsRequest that)) return false;
        return Objects.equals(surfaces, that.surfaces);
    }

    @Override
    public int hashCode() { return Objects.hash(surfaces); }

    @Override
    public String toString() { return "ParkTabsRequest" + toWire(); }

    public static final class Builder {
        private List<Object> surfaces;
        private boolean surfacesSet;

        public Builder surfaces(List<Object> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public ParkTabsRequest build() { return new ParkTabsRequest(this); }
    }
}

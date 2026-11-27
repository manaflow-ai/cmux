// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-resources request. Protocol v12; authority: control. */
public final class TerminalResourcesRequest implements WireValue {
    private final Field<List<UInt64>> surfaces;

    private TerminalResourcesRequest(Builder builder) {
        this.surfaces = builder.surfaces.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<UInt64>> surfaces() { return surfaces; }

    public static TerminalResourcesRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResourcesRequest");
        Builder builder = builder();
        Object rawSurfaces = Wire.optional(object, "surfaces");
        if (!Wire.isMissing(rawSurfaces)) {
            builder.surfaces(rawSurfaces == null ? null : Wire.array(rawSurfaces, "TerminalResourcesRequest.surfaces", item -> Wire.uint64(item, "TerminalResourcesRequest.surfaces item")));
        }
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
        if (!(other instanceof TerminalResourcesRequest that)) return false;
        return Objects.equals(surfaces, that.surfaces);
    }

    @Override
    public int hashCode() { return Objects.hash(surfaces); }

    @Override
    public String toString() { return "TerminalResourcesRequest" + toWire(); }

    public static final class Builder {
        private Field<List<UInt64>> surfaces = Field.omitted();

        public Builder surfaces(List<UInt64> value) {
            this.surfaces = Field.ofNullable(value);
            return this;
        }
        public TerminalResourcesRequest build() { return new TerminalResourcesRequest(this); }
    }
}

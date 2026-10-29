// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable reattach-view request. Protocol v12; authority: control. */
public final class ReattachViewRequest implements WireValue {
    private final Field<Boolean> counts;
    private final UInt64 surface;

    private ReattachViewRequest(Builder builder) {
        this.counts = builder.counts;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> counts() { return counts; }
    public UInt64 surface() { return surface; }

    public static ReattachViewRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReattachViewRequest");
        Builder builder = builder();
        Object rawCounts = Wire.optional(object, "counts");
        if (!Wire.isMissing(rawCounts)) {
            builder.counts(rawCounts == null ? null : Wire.bool(rawCounts, "ReattachViewRequest.counts"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ReattachViewRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "counts", counts);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReattachViewRequest that)) return false;
        return Objects.equals(counts, that.counts) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(counts, surface); }

    @Override
    public String toString() { return "ReattachViewRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> counts = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder counts(Boolean value) {
            this.counts = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ReattachViewRequest build() { return new ReattachViewRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppliedPane implements WireValue {
    private final UInt64 pane;
    private final UInt64 surface;

    private AppliedPane(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public UInt64 surface() { return surface; }

    public static AppliedPane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppliedPane");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "AppliedPane.pane"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AppliedPane.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppliedPane that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, surface); }

    @Override
    public String toString() { return "AppliedPane" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AppliedPane build() { return new AppliedPane(this); }
    }
}

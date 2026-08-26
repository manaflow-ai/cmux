// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable rename-surface request. Protocol v5; authority: control. */
public final class RenameSurfaceRequest implements WireValue {
    private final String name;
    private final UInt64 surface;

    private RenameSurfaceRequest(Builder builder) {
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String name() { return name; }
    public UInt64 surface() { return surface; }

    public static RenameSurfaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenameSurfaceRequest");
        Builder builder = builder();
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "RenameSurfaceRequest.name"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "RenameSurfaceRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "name", name);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenameSurfaceRequest that)) return false;
        return Objects.equals(name, that.name) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(name, surface); }

    @Override
    public String toString() { return "RenameSurfaceRequest" + toWire(); }

    public static final class Builder {
        private String name;
        private boolean nameSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public RenameSurfaceRequest build() { return new RenameSurfaceRequest(this); }
    }
}

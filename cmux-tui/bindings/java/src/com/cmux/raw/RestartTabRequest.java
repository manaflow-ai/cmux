// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable restart-tab request. Protocol v12; authority: control. */
public final class RestartTabRequest implements WireValue {
    private final Object surface;

    private RestartTabRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Object surface() { return surface; }

    public static RestartTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RestartTabRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.immutableJson(rawSurface));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RestartTabRequest that)) return false;
        return Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(surface); }

    @Override
    public String toString() { return "RestartTabRequest" + toWire(); }

    public static final class Builder {
        private Object surface;
        private boolean surfaceSet;

        public Builder surface(Object value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public RestartTabRequest build() { return new RestartTabRequest(this); }
    }
}

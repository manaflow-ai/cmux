// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-attach-visibility request. Protocol v12; authority: frontend. */
public final class SetAttachVisibilityRequest implements WireValue {
    private final UInt64 surface;
    private final boolean visible;

    private SetAttachVisibilityRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.visibleSet) throw new IllegalArgumentException("visible is required");
        this.visible = builder.visible;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public boolean visible() { return visible; }

    public static SetAttachVisibilityRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetAttachVisibilityRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SetAttachVisibilityRequest.surface"));
        Object rawVisible = Wire.required(object, "visible");
        builder.visible(Wire.bool(rawVisible, "SetAttachVisibilityRequest.visible"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "visible", visible);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetAttachVisibilityRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(visible, that.visible);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, visible); }

    @Override
    public String toString() { return "SetAttachVisibilityRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private Boolean visible;
        private boolean visibleSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder visible(boolean value) {
            this.visible = value;
            this.visibleSet = true;
            return this;
        }
        public SetAttachVisibilityRequest build() { return new SetAttachVisibilityRequest(this); }
    }
}

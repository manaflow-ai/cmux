// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-tab-pinned request. Protocol v12; authority: control. */
public final class SetTabPinnedRequest implements WireValue {
    private final boolean pinned;
    private final UInt64 surface;

    private SetTabPinnedRequest(Builder builder) {
        if (!builder.pinnedSet) throw new IllegalArgumentException("pinned is required");
        this.pinned = builder.pinned;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public boolean pinned() { return pinned; }
    public UInt64 surface() { return surface; }

    public static SetTabPinnedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTabPinnedRequest");
        Builder builder = builder();
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "SetTabPinnedRequest.pinned"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SetTabPinnedRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTabPinnedRequest that)) return false;
        return Objects.equals(pinned, that.pinned) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(pinned, surface); }

    @Override
    public String toString() { return "SetTabPinnedRequest" + toWire(); }

    public static final class Builder {
        private Boolean pinned;
        private boolean pinnedSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder pinned(boolean value) {
            this.pinned = value;
            this.pinnedSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SetTabPinnedRequest build() { return new SetTabPinnedRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable copy request. Protocol v6; authority: control. */
public final class CopyRequest implements WireValue {
    private final CopyRequestMode mode;
    private final UInt64 surface;

    private CopyRequest(Builder builder) {
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public CopyRequestMode mode() { return mode; }
    public UInt64 surface() { return surface; }

    public static CopyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CopyRequest");
        Builder builder = builder();
        Object rawMode = Wire.required(object, "mode");
        builder.mode(CopyRequestMode.fromWire(rawMode));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "CopyRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mode", mode);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CopyRequest that)) return false;
        return Objects.equals(mode, that.mode) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(mode, surface); }

    @Override
    public String toString() { return "CopyRequest" + toWire(); }

    public static final class Builder {
        private CopyRequestMode mode;
        private boolean modeSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder mode(CopyRequestMode value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public CopyRequest build() { return new CopyRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable release-attached-view-size request. Protocol v10; authority: frontend. */
public final class ReleaseAttachedViewSizeRequest implements WireValue {
    private final String lease;
    private final UInt64 surface;

    private ReleaseAttachedViewSizeRequest(Builder builder) {
        if (!builder.leaseSet) throw new IllegalArgumentException("lease is required");
        this.lease = Wire.nonNull(builder.lease, "lease");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String lease() { return lease; }
    public UInt64 surface() { return surface; }

    public static ReleaseAttachedViewSizeRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReleaseAttachedViewSizeRequest");
        Builder builder = builder();
        Object rawLease = Wire.required(object, "lease");
        builder.lease(Wire.string(rawLease, "ReleaseAttachedViewSizeRequest.lease"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ReleaseAttachedViewSizeRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "lease", lease);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReleaseAttachedViewSizeRequest that)) return false;
        return Objects.equals(lease, that.lease) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(lease, surface); }

    @Override
    public String toString() { return "ReleaseAttachedViewSizeRequest" + toWire(); }

    public static final class Builder {
        private String lease;
        private boolean leaseSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder lease(String value) {
            this.lease = value;
            this.leaseSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ReleaseAttachedViewSizeRequest build() { return new ReleaseAttachedViewSizeRequest(this); }
    }
}

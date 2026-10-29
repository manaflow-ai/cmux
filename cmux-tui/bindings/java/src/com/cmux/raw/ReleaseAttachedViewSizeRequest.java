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
    private final Field<String> lease;
    private final UInt64 surface;
    private final Field<String> view;

    private ReleaseAttachedViewSizeRequest(Builder builder) {
        this.lease = builder.lease;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.view = builder.view;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> lease() { return lease; }
    public UInt64 surface() { return surface; }
    public Field<String> view() { return view; }

    public static ReleaseAttachedViewSizeRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReleaseAttachedViewSizeRequest");
        Builder builder = builder();
        Object rawLease = Wire.optional(object, "lease");
        if (!Wire.isMissing(rawLease)) {
            builder.lease(rawLease == null ? null : Wire.string(rawLease, "ReleaseAttachedViewSizeRequest.lease"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ReleaseAttachedViewSizeRequest.surface"));
        Object rawView = Wire.optional(object, "view");
        if (!Wire.isMissing(rawView)) {
            builder.view(rawView == null ? null : Wire.string(rawView, "ReleaseAttachedViewSizeRequest.view"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "lease", lease);
        Wire.put(object, "surface", surface);
        Wire.put(object, "view", view);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReleaseAttachedViewSizeRequest that)) return false;
        return Objects.equals(lease, that.lease) && Objects.equals(surface, that.surface) && Objects.equals(view, that.view);
    }

    @Override
    public int hashCode() { return Objects.hash(lease, surface, view); }

    @Override
    public String toString() { return "ReleaseAttachedViewSizeRequest" + toWire(); }

    public static final class Builder {
        private Field<String> lease = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> view = Field.omitted();

        public Builder lease(String value) {
            this.lease = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder view(String value) {
            this.view = Field.ofNullable(value);
            return this;
        }
        public ReleaseAttachedViewSizeRequest build() { return new ReleaseAttachedViewSizeRequest(this); }
    }
}

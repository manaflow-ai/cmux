// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-unmount request. Protocol v12; authority: local-admin. */
public final class AppsUnmountRequest implements WireValue {
    private final String mountId;
    private final Field<AppOrigin> origin;

    private AppsUnmountRequest(Builder builder) {
        if (!builder.mountIdSet) throw new IllegalArgumentException("mount_id is required");
        this.mountId = Wire.nonNull(builder.mountId, "mount_id");
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public String mountId() { return mountId; }
    public Field<AppOrigin> origin() { return origin; }

    public static AppsUnmountRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsUnmountRequest");
        Builder builder = builder();
        Object rawMountId = Wire.required(object, "mount_id");
        builder.mountId(Wire.string(rawMountId, "AppsUnmountRequest.mount_id"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mount_id", mountId);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsUnmountRequest that)) return false;
        return Objects.equals(mountId, that.mountId) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(mountId, origin); }

    @Override
    public String toString() { return "AppsUnmountRequest" + toWire(); }

    public static final class Builder {
        private String mountId;
        private boolean mountIdSet;
        private Field<AppOrigin> origin = Field.omitted();

        public Builder mountId(String value) {
            this.mountId = value;
            this.mountIdSet = true;
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public AppsUnmountRequest build() { return new AppsUnmountRequest(this); }
    }
}

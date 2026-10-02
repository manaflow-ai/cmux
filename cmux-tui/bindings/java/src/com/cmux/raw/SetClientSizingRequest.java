// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-client-sizing request. Protocol v10; authority: control. */
public final class SetClientSizingRequest implements WireValue {
    private final Field<UInt64> client;
    private final boolean enabled;
    private final Field<Boolean> exclusive;
    private final UInt64 surface;

    private SetClientSizingRequest(Builder builder) {
        this.client = builder.client;
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
        this.exclusive = builder.exclusive;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> client() { return client; }
    public boolean enabled() { return enabled; }
    public Field<Boolean> exclusive() { return exclusive; }
    public UInt64 surface() { return surface; }

    public static SetClientSizingRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetClientSizingRequest");
        Builder builder = builder();
        Object rawClient = Wire.optional(object, "client");
        if (!Wire.isMissing(rawClient)) {
            builder.client(rawClient == null ? null : Wire.uint64(rawClient, "SetClientSizingRequest.client"));
        }
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "SetClientSizingRequest.enabled"));
        Object rawExclusive = Wire.optional(object, "exclusive");
        if (!Wire.isMissing(rawExclusive)) {
            builder.exclusive(Wire.bool(rawExclusive, "SetClientSizingRequest.exclusive"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SetClientSizingRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client", client);
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "exclusive", exclusive);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetClientSizingRequest that)) return false;
        return Objects.equals(client, that.client) && Objects.equals(enabled, that.enabled) && Objects.equals(exclusive, that.exclusive) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(client, enabled, exclusive, surface); }

    @Override
    public String toString() { return "SetClientSizingRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> client = Field.omitted();
        private Boolean enabled;
        private boolean enabledSet;
        private Field<Boolean> exclusive = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder client(UInt64 value) {
            this.client = Field.ofNullable(value);
            return this;
        }
        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public Builder exclusive(Boolean value) {
            this.exclusive = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SetClientSizingRequest build() { return new SetClientSizingRequest(this); }
    }
}

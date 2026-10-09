// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable detach-client request. Protocol v6; authority: control. */
public final class DetachClientRequest implements WireValue {
    private final Field<SizeDetachActor> by;
    private final Object client;
    private final Field<UInt64> surface;

    private DetachClientRequest(Builder builder) {
        this.by = builder.by;
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        this.surface = builder.surface;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SizeDetachActor> by() { return by; }
    public Object client() { return client; }
    public Field<UInt64> surface() { return surface; }

    public static DetachClientRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DetachClientRequest");
        Builder builder = builder();
        Object rawBy = Wire.optional(object, "by");
        if (!Wire.isMissing(rawBy)) {
            builder.by(rawBy == null ? null : SizeDetachActor.fromWire(rawBy));
        }
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.immutableJson(rawClient));
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "DetachClientRequest.surface"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "by", by);
        Wire.put(object, "client", client);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DetachClientRequest that)) return false;
        return Objects.equals(by, that.by) && Objects.equals(client, that.client) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(by, client, surface); }

    @Override
    public String toString() { return "DetachClientRequest" + toWire(); }

    public static final class Builder {
        private Field<SizeDetachActor> by = Field.omitted();
        private Object client;
        private boolean clientSet;
        private Field<UInt64> surface = Field.omitted();

        public Builder by(SizeDetachActor value) {
            this.by = Field.ofNullable(value);
            return this;
        }
        public Builder client(Object value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public DetachClientRequest build() { return new DetachClientRequest(this); }
    }
}

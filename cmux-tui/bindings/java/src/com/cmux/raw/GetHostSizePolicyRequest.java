// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable get-host-size-policy request. Protocol v12; authority: control. */
public final class GetHostSizePolicyRequest implements WireValue {
    private final Field<UInt64> surface;

    private GetHostSizePolicyRequest(Builder builder) {
        this.surface = builder.surface;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> surface() { return surface; }

    public static GetHostSizePolicyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetHostSizePolicyRequest");
        Builder builder = builder();
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "GetHostSizePolicyRequest.surface"));
        }
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
        if (!(other instanceof GetHostSizePolicyRequest that)) return false;
        return Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(surface); }

    @Override
    public String toString() { return "GetHostSizePolicyRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> surface = Field.omitted();

        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public GetHostSizePolicyRequest build() { return new GetHostSizePolicyRequest(this); }
    }
}

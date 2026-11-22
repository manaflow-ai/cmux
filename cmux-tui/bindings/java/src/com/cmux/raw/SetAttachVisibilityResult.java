// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetAttachVisibilityResult implements WireValue {
    private final long viewers;

    private SetAttachVisibilityResult(Builder builder) {
        if (!builder.viewersSet) throw new IllegalArgumentException("viewers is required");
        this.viewers = builder.viewers;
    }

    public static Builder builder() { return new Builder(); }

    public long viewers() { return viewers; }

    public static SetAttachVisibilityResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetAttachVisibilityResult");
        Builder builder = builder();
        Object rawViewers = Wire.required(object, "viewers");
        builder.viewers(Wire.uint32(rawViewers, "SetAttachVisibilityResult.viewers"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "viewers", viewers);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetAttachVisibilityResult that)) return false;
        return Objects.equals(viewers, that.viewers);
    }

    @Override
    public int hashCode() { return Objects.hash(viewers); }

    @Override
    public String toString() { return "SetAttachVisibilityResult" + toWire(); }

    public static final class Builder {
        private Long viewers;
        private boolean viewersSet;

        public Builder viewers(long value) {
            this.viewers = value;
            this.viewersSet = true;
            return this;
        }
        public SetAttachVisibilityResult build() { return new SetAttachVisibilityResult(this); }
    }
}

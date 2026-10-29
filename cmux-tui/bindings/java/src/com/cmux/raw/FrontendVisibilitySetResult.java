// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FrontendVisibilitySetResult implements WireValue {
    private final UInt64 released;
    private final UInt64 visible;

    private FrontendVisibilitySetResult(Builder builder) {
        if (!builder.releasedSet) throw new IllegalArgumentException("released is required");
        this.released = Wire.nonNull(builder.released, "released");
        if (!builder.visibleSet) throw new IllegalArgumentException("visible is required");
        this.visible = builder.visible;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 released() { return released; }
    public UInt64 visible() { return visible; }

    public static FrontendVisibilitySetResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendVisibilitySetResult");
        Builder builder = builder();
        Object rawReleased = Wire.required(object, "released");
        builder.released(Wire.uint64(rawReleased, "FrontendVisibilitySetResult.released"));
        Object rawVisible = Wire.required(object, "visible");
        builder.visible(rawVisible == null ? null : Wire.uint64(rawVisible, "FrontendVisibilitySetResult.visible"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "released", released);
        Wire.put(object, "visible", visible);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendVisibilitySetResult that)) return false;
        return Objects.equals(released, that.released) && Objects.equals(visible, that.visible);
    }

    @Override
    public int hashCode() { return Objects.hash(released, visible); }

    @Override
    public String toString() { return "FrontendVisibilitySetResult" + toWire(); }

    public static final class Builder {
        private UInt64 released;
        private boolean releasedSet;
        private UInt64 visible;
        private boolean visibleSet;

        public Builder released(UInt64 value) {
            this.released = value;
            this.releasedSet = true;
            return this;
        }
        public Builder visible(UInt64 value) {
            this.visible = value;
            this.visibleSet = true;
            return this;
        }
        public FrontendVisibilitySetResult build() { return new FrontendVisibilitySetResult(this); }
    }
}

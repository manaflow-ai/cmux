// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable frontend.visibility.set request. Protocol v12; authority: local-admin. */
public final class FrontendVisibilitySetRequest implements WireValue {
    private final List<UInt64> visible;

    private FrontendVisibilitySetRequest(Builder builder) {
        if (!builder.visibleSet) throw new IllegalArgumentException("visible is required");
        this.visible = builder.visible == null ? null : List.copyOf(builder.visible);
    }

    public static Builder builder() { return new Builder(); }

    public List<UInt64> visible() { return visible; }

    public static FrontendVisibilitySetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendVisibilitySetRequest");
        Builder builder = builder();
        Object rawVisible = Wire.required(object, "visible");
        builder.visible(rawVisible == null ? null : Wire.array(rawVisible, "FrontendVisibilitySetRequest.visible", item -> Wire.uint64(item, "FrontendVisibilitySetRequest.visible item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "visible", visible);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendVisibilitySetRequest that)) return false;
        return Objects.equals(visible, that.visible);
    }

    @Override
    public int hashCode() { return Objects.hash(visible); }

    @Override
    public String toString() { return "FrontendVisibilitySetRequest" + toWire(); }

    public static final class Builder {
        private List<UInt64> visible;
        private boolean visibleSet;

        public Builder visible(List<UInt64> value) {
            this.visible = value;
            this.visibleSet = true;
            return this;
        }
        public FrontendVisibilitySetRequest build() { return new FrontendVisibilitySetRequest(this); }
    }
}

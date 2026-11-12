// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GetAppearanceResult implements WireValue {
    private final Appearance appearance;

    private GetAppearanceResult(Builder builder) {
        if (!builder.appearanceSet) throw new IllegalArgumentException("appearance is required");
        this.appearance = Wire.nonNull(builder.appearance, "appearance");
    }

    public static Builder builder() { return new Builder(); }

    public Appearance appearance() { return appearance; }

    public static GetAppearanceResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetAppearanceResult");
        Builder builder = builder();
        Object rawAppearance = Wire.required(object, "appearance");
        builder.appearance(Appearance.fromWire(rawAppearance));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "appearance", appearance);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetAppearanceResult that)) return false;
        return Objects.equals(appearance, that.appearance);
    }

    @Override
    public int hashCode() { return Objects.hash(appearance); }

    @Override
    public String toString() { return "GetAppearanceResult" + toWire(); }

    public static final class Builder {
        private Appearance appearance;
        private boolean appearanceSet;

        public Builder appearance(Appearance value) {
            this.appearance = value;
            this.appearanceSet = true;
            return this;
        }
        public GetAppearanceResult build() { return new GetAppearanceResult(this); }
    }
}

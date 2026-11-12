// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceGroups implements WireValue {
    private final Object gradient;
    private final Object palette;

    private AppearanceGroups(Builder builder) {
        if (!builder.gradientSet) throw new IllegalArgumentException("gradient is required");
        this.gradient = builder.gradient == null ? null : Wire.immutableJson(builder.gradient);
        if (!builder.paletteSet) throw new IllegalArgumentException("palette is required");
        this.palette = builder.palette == null ? null : Wire.immutableJson(builder.palette);
    }

    public static Builder builder() { return new Builder(); }

    public Object gradient() { return gradient; }
    public Object palette() { return palette; }

    public static AppearanceGroups fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceGroups");
        Builder builder = builder();
        Object rawGradient = Wire.required(object, "gradient");
        builder.gradient(rawGradient == null ? null : Wire.immutableJson(rawGradient));
        Object rawPalette = Wire.required(object, "palette");
        builder.palette(rawPalette == null ? null : Wire.immutableJson(rawPalette));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "gradient", gradient);
        Wire.put(object, "palette", palette);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceGroups that)) return false;
        return Objects.equals(gradient, that.gradient) && Objects.equals(palette, that.palette);
    }

    @Override
    public int hashCode() { return Objects.hash(gradient, palette); }

    @Override
    public String toString() { return "AppearanceGroups" + toWire(); }

    public static final class Builder {
        private Object gradient;
        private boolean gradientSet;
        private Object palette;
        private boolean paletteSet;

        public Builder gradient(Object value) {
            this.gradient = value;
            this.gradientSet = true;
            return this;
        }
        public Builder palette(Object value) {
            this.palette = value;
            this.paletteSet = true;
            return this;
        }
        public AppearanceGroups build() { return new AppearanceGroups(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceTerminal implements WireValue {
    private final Object fontFamily;
    private final Object fontSize;

    private AppearanceTerminal(Builder builder) {
        if (!builder.fontFamilySet) throw new IllegalArgumentException("font_family is required");
        this.fontFamily = builder.fontFamily == null ? null : Wire.immutableJson(builder.fontFamily);
        if (!builder.fontSizeSet) throw new IllegalArgumentException("font_size is required");
        this.fontSize = builder.fontSize == null ? null : Wire.immutableJson(builder.fontSize);
    }

    public static Builder builder() { return new Builder(); }

    public Object fontFamily() { return fontFamily; }
    public Object fontSize() { return fontSize; }

    public static AppearanceTerminal fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceTerminal");
        Builder builder = builder();
        Object rawFontFamily = Wire.required(object, "font_family");
        builder.fontFamily(rawFontFamily == null ? null : Wire.immutableJson(rawFontFamily));
        Object rawFontSize = Wire.required(object, "font_size");
        builder.fontSize(rawFontSize == null ? null : Wire.immutableJson(rawFontSize));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "font_family", fontFamily);
        Wire.put(object, "font_size", fontSize);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceTerminal that)) return false;
        return Objects.equals(fontFamily, that.fontFamily) && Objects.equals(fontSize, that.fontSize);
    }

    @Override
    public int hashCode() { return Objects.hash(fontFamily, fontSize); }

    @Override
    public String toString() { return "AppearanceTerminal" + toWire(); }

    public static final class Builder {
        private Object fontFamily;
        private boolean fontFamilySet;
        private Object fontSize;
        private boolean fontSizeSet;

        public Builder fontFamily(Object value) {
            this.fontFamily = value;
            this.fontFamilySet = true;
            return this;
        }
        public Builder fontSize(Object value) {
            this.fontSize = value;
            this.fontSizeSet = true;
            return this;
        }
        public AppearanceTerminal build() { return new AppearanceTerminal(this); }
    }
}

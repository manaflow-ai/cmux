// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceThemeSide implements WireValue {
    private final AppearanceThemeInput input;
    private final String name;

    private AppearanceThemeSide(Builder builder) {
        if (!builder.inputSet) throw new IllegalArgumentException("input is required");
        this.input = Wire.nonNull(builder.input, "input");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
    }

    public static Builder builder() { return new Builder(); }

    public AppearanceThemeInput input() { return input; }
    public String name() { return name; }

    public static AppearanceThemeSide fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceThemeSide");
        Builder builder = builder();
        Object rawInput = Wire.required(object, "input");
        builder.input(AppearanceThemeInput.fromWire(rawInput));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "AppearanceThemeSide.name"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "input", input);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceThemeSide that)) return false;
        return Objects.equals(input, that.input) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(input, name); }

    @Override
    public String toString() { return "AppearanceThemeSide" + toWire(); }

    public static final class Builder {
        private AppearanceThemeInput input;
        private boolean inputSet;
        private String name;
        private boolean nameSet;

        public Builder input(AppearanceThemeInput value) {
            this.input = value;
            this.inputSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public AppearanceThemeSide build() { return new AppearanceThemeSide(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceTheme implements WireValue {
    private final AppearanceThemeSide dark;
    private final boolean followsSystem;
    private final AppearanceThemeSide light;

    private AppearanceTheme(Builder builder) {
        if (!builder.darkSet) throw new IllegalArgumentException("dark is required");
        this.dark = Wire.nonNull(builder.dark, "dark");
        if (!builder.followsSystemSet) throw new IllegalArgumentException("follows_system is required");
        this.followsSystem = builder.followsSystem;
        if (!builder.lightSet) throw new IllegalArgumentException("light is required");
        this.light = Wire.nonNull(builder.light, "light");
    }

    public static Builder builder() { return new Builder(); }

    public AppearanceThemeSide dark() { return dark; }
    public boolean followsSystem() { return followsSystem; }
    public AppearanceThemeSide light() { return light; }

    public static AppearanceTheme fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceTheme");
        Builder builder = builder();
        Object rawDark = Wire.required(object, "dark");
        builder.dark(AppearanceThemeSide.fromWire(rawDark));
        Object rawFollowsSystem = Wire.required(object, "follows_system");
        builder.followsSystem(Wire.bool(rawFollowsSystem, "AppearanceTheme.follows_system"));
        Object rawLight = Wire.required(object, "light");
        builder.light(AppearanceThemeSide.fromWire(rawLight));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dark", dark);
        Wire.put(object, "follows_system", followsSystem);
        Wire.put(object, "light", light);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceTheme that)) return false;
        return Objects.equals(dark, that.dark) && Objects.equals(followsSystem, that.followsSystem) && Objects.equals(light, that.light);
    }

    @Override
    public int hashCode() { return Objects.hash(dark, followsSystem, light); }

    @Override
    public String toString() { return "AppearanceTheme" + toWire(); }

    public static final class Builder {
        private AppearanceThemeSide dark;
        private boolean darkSet;
        private Boolean followsSystem;
        private boolean followsSystemSet;
        private AppearanceThemeSide light;
        private boolean lightSet;

        public Builder dark(AppearanceThemeSide value) {
            this.dark = value;
            this.darkSet = true;
            return this;
        }
        public Builder followsSystem(boolean value) {
            this.followsSystem = value;
            this.followsSystemSet = true;
            return this;
        }
        public Builder light(AppearanceThemeSide value) {
            this.light = value;
            this.lightSet = true;
            return this;
        }
        public AppearanceTheme build() { return new AppearanceTheme(this); }
    }
}

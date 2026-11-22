// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable update-browser-profile request. Protocol v12; authority: control. */
public final class UpdateBrowserProfileRequest implements WireValue {
    private final String browserProfile;
    private final Field<String> color;
    private final Field<String> icon;
    private final Field<String> name;

    private UpdateBrowserProfileRequest(Builder builder) {
        if (!builder.browserProfileSet) throw new IllegalArgumentException("browser_profile is required");
        this.browserProfile = Wire.nonNull(builder.browserProfile, "browser_profile");
        this.color = builder.color;
        this.icon = builder.icon;
        this.name = builder.name;
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfile() { return browserProfile; }
    public Field<String> color() { return color; }
    public Field<String> icon() { return icon; }
    public Field<String> name() { return name; }

    public static UpdateBrowserProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UpdateBrowserProfileRequest");
        Builder builder = builder();
        Object rawBrowserProfile = Wire.required(object, "browser_profile");
        builder.browserProfile(Wire.string(rawBrowserProfile, "UpdateBrowserProfileRequest.browser_profile"));
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "UpdateBrowserProfileRequest.color"));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "UpdateBrowserProfileRequest.icon"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "UpdateBrowserProfileRequest.name"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile", browserProfile);
        Wire.put(object, "color", color);
        Wire.put(object, "icon", icon);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UpdateBrowserProfileRequest that)) return false;
        return Objects.equals(browserProfile, that.browserProfile) && Objects.equals(color, that.color) && Objects.equals(icon, that.icon) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfile, color, icon, name); }

    @Override
    public String toString() { return "UpdateBrowserProfileRequest" + toWire(); }

    public static final class Builder {
        private String browserProfile;
        private boolean browserProfileSet;
        private Field<String> color = Field.omitted();
        private Field<String> icon = Field.omitted();
        private Field<String> name = Field.omitted();

        public Builder browserProfile(String value) {
            this.browserProfile = value;
            this.browserProfileSet = true;
            return this;
        }
        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public UpdateBrowserProfileRequest build() { return new UpdateBrowserProfileRequest(this); }
    }
}

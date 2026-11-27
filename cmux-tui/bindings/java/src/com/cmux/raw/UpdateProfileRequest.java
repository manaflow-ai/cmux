// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable update-profile request. Protocol v12; authority: control. */
public final class UpdateProfileRequest implements WireValue {
    private final Field<String> browserProfileId;
    private final Field<String> color;
    private final Field<String> defaultSessionId;
    private final Field<Object> defaults;
    private final Field<String> icon;
    private final Field<String> name;
    private final String profile;
    private final Field<String> theme;

    private UpdateProfileRequest(Builder builder) {
        this.browserProfileId = builder.browserProfileId;
        this.color = builder.color;
        this.defaultSessionId = builder.defaultSessionId;
        this.defaults = builder.defaults.map(value -> Wire.immutableJson(value));
        this.icon = builder.icon;
        this.name = builder.name;
        if (!builder.profileSet) throw new IllegalArgumentException("profile is required");
        this.profile = Wire.nonNull(builder.profile, "profile");
        this.theme = builder.theme;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> browserProfileId() { return browserProfileId; }
    public Field<String> color() { return color; }
    public Field<String> defaultSessionId() { return defaultSessionId; }
    public Field<Object> defaults() { return defaults; }
    public Field<String> icon() { return icon; }
    public Field<String> name() { return name; }
    public String profile() { return profile; }
    public Field<String> theme() { return theme; }

    public static UpdateProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UpdateProfileRequest");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.optional(object, "browser_profile_id");
        if (!Wire.isMissing(rawBrowserProfileId)) {
            builder.browserProfileId(rawBrowserProfileId == null ? null : Wire.string(rawBrowserProfileId, "UpdateProfileRequest.browser_profile_id"));
        }
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "UpdateProfileRequest.color"));
        }
        Object rawDefaultSessionId = Wire.optional(object, "default_session_id");
        if (!Wire.isMissing(rawDefaultSessionId)) {
            builder.defaultSessionId(rawDefaultSessionId == null ? null : Wire.string(rawDefaultSessionId, "UpdateProfileRequest.default_session_id"));
        }
        Object rawDefaults = Wire.optional(object, "defaults");
        if (!Wire.isMissing(rawDefaults)) {
            builder.defaults(rawDefaults == null ? null : Wire.immutableJson(rawDefaults));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "UpdateProfileRequest.icon"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "UpdateProfileRequest.name"));
        }
        Object rawProfile = Wire.required(object, "profile");
        builder.profile(Wire.string(rawProfile, "UpdateProfileRequest.profile"));
        Object rawTheme = Wire.optional(object, "theme");
        if (!Wire.isMissing(rawTheme)) {
            builder.theme(rawTheme == null ? null : Wire.string(rawTheme, "UpdateProfileRequest.theme"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "color", color);
        Wire.put(object, "default_session_id", defaultSessionId);
        Wire.put(object, "defaults", defaults);
        Wire.put(object, "icon", icon);
        Wire.put(object, "name", name);
        Wire.put(object, "profile", profile);
        Wire.put(object, "theme", theme);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UpdateProfileRequest that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(color, that.color) && Objects.equals(defaultSessionId, that.defaultSessionId) && Objects.equals(defaults, that.defaults) && Objects.equals(icon, that.icon) && Objects.equals(name, that.name) && Objects.equals(profile, that.profile) && Objects.equals(theme, that.theme);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId, color, defaultSessionId, defaults, icon, name, profile, theme); }

    @Override
    public String toString() { return "UpdateProfileRequest" + toWire(); }

    public static final class Builder {
        private Field<String> browserProfileId = Field.omitted();
        private Field<String> color = Field.omitted();
        private Field<String> defaultSessionId = Field.omitted();
        private Field<Object> defaults = Field.omitted();
        private Field<String> icon = Field.omitted();
        private Field<String> name = Field.omitted();
        private String profile;
        private boolean profileSet;
        private Field<String> theme = Field.omitted();

        public Builder browserProfileId(String value) {
            this.browserProfileId = Field.ofNullable(value);
            return this;
        }
        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder defaultSessionId(String value) {
            this.defaultSessionId = Field.ofNullable(value);
            return this;
        }
        public Builder defaults(Object value) {
            this.defaults = Field.ofNullable(value);
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
        public Builder profile(String value) {
            this.profile = value;
            this.profileSet = true;
            return this;
        }
        public Builder theme(String value) {
            this.theme = Field.ofNullable(value);
            return this;
        }
        public UpdateProfileRequest build() { return new UpdateProfileRequest(this); }
    }
}

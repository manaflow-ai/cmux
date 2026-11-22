// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-profile request. Protocol v12; authority: control. */
public final class CreateProfileRequest implements WireValue {
    private final Field<String> browserProfileId;
    private final Field<String> color;
    private final Field<String> defaultSessionId;
    private final Field<Object> defaults;
    private final Field<List<String>> follows;
    private final Field<String> icon;
    private final Field<UInt64> index;
    private final String name;
    private final Field<String> profile;
    private final Field<String> theme;

    private CreateProfileRequest(Builder builder) {
        this.browserProfileId = builder.browserProfileId;
        this.color = builder.color;
        this.defaultSessionId = builder.defaultSessionId;
        this.defaults = builder.defaults.map(value -> Wire.immutableJson(value));
        this.follows = builder.follows.map(value -> List.copyOf(value));
        this.icon = builder.icon;
        this.index = builder.index;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.profile = builder.profile;
        this.theme = builder.theme;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> browserProfileId() { return browserProfileId; }
    public Field<String> color() { return color; }
    public Field<String> defaultSessionId() { return defaultSessionId; }
    public Field<Object> defaults() { return defaults; }
    public Field<List<String>> follows() { return follows; }
    public Field<String> icon() { return icon; }
    public Field<UInt64> index() { return index; }
    public String name() { return name; }
    public Field<String> profile() { return profile; }
    public Field<String> theme() { return theme; }

    public static CreateProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateProfileRequest");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.optional(object, "browser_profile_id");
        if (!Wire.isMissing(rawBrowserProfileId)) {
            builder.browserProfileId(rawBrowserProfileId == null ? null : Wire.string(rawBrowserProfileId, "CreateProfileRequest.browser_profile_id"));
        }
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "CreateProfileRequest.color"));
        }
        Object rawDefaultSessionId = Wire.optional(object, "default_session_id");
        if (!Wire.isMissing(rawDefaultSessionId)) {
            builder.defaultSessionId(rawDefaultSessionId == null ? null : Wire.string(rawDefaultSessionId, "CreateProfileRequest.default_session_id"));
        }
        Object rawDefaults = Wire.optional(object, "defaults");
        if (!Wire.isMissing(rawDefaults)) {
            builder.defaults(rawDefaults == null ? null : Wire.immutableJson(rawDefaults));
        }
        Object rawFollows = Wire.optional(object, "follows");
        if (!Wire.isMissing(rawFollows)) {
            builder.follows(rawFollows == null ? null : Wire.array(rawFollows, "CreateProfileRequest.follows", item -> Wire.string(item, "CreateProfileRequest.follows item")));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "CreateProfileRequest.icon"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "CreateProfileRequest.index"));
        }
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "CreateProfileRequest.name"));
        Object rawProfile = Wire.optional(object, "profile");
        if (!Wire.isMissing(rawProfile)) {
            builder.profile(rawProfile == null ? null : Wire.string(rawProfile, "CreateProfileRequest.profile"));
        }
        Object rawTheme = Wire.optional(object, "theme");
        if (!Wire.isMissing(rawTheme)) {
            builder.theme(rawTheme == null ? null : Wire.string(rawTheme, "CreateProfileRequest.theme"));
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
        Wire.put(object, "follows", follows);
        Wire.put(object, "icon", icon);
        Wire.put(object, "index", index);
        Wire.put(object, "name", name);
        Wire.put(object, "profile", profile);
        Wire.put(object, "theme", theme);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateProfileRequest that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(color, that.color) && Objects.equals(defaultSessionId, that.defaultSessionId) && Objects.equals(defaults, that.defaults) && Objects.equals(follows, that.follows) && Objects.equals(icon, that.icon) && Objects.equals(index, that.index) && Objects.equals(name, that.name) && Objects.equals(profile, that.profile) && Objects.equals(theme, that.theme);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId, color, defaultSessionId, defaults, follows, icon, index, name, profile, theme); }

    @Override
    public String toString() { return "CreateProfileRequest" + toWire(); }

    public static final class Builder {
        private Field<String> browserProfileId = Field.omitted();
        private Field<String> color = Field.omitted();
        private Field<String> defaultSessionId = Field.omitted();
        private Field<Object> defaults = Field.omitted();
        private Field<List<String>> follows = Field.omitted();
        private Field<String> icon = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private String name;
        private boolean nameSet;
        private Field<String> profile = Field.omitted();
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
        public Builder follows(List<String> value) {
            this.follows = Field.ofNullable(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder profile(String value) {
            this.profile = Field.ofNullable(value);
            return this;
        }
        public Builder theme(String value) {
            this.theme = Field.ofNullable(value);
            return this;
        }
        public CreateProfileRequest build() { return new CreateProfileRequest(this); }
    }
}

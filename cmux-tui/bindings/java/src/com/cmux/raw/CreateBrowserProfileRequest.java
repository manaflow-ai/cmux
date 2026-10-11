// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-browser-profile request. Protocol v12; authority: control. */
public final class CreateBrowserProfileRequest implements WireValue {
    private final Field<String> browserProfile;
    private final Field<String> color;
    private final Field<String> icon;
    private final Field<UInt64> index;
    private final String name;
    private final Field<Object> source;

    private CreateBrowserProfileRequest(Builder builder) {
        this.browserProfile = builder.browserProfile;
        this.color = builder.color;
        this.icon = builder.icon;
        this.index = builder.index;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.source = builder.source.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> browserProfile() { return browserProfile; }
    public Field<String> color() { return color; }
    public Field<String> icon() { return icon; }
    public Field<UInt64> index() { return index; }
    public String name() { return name; }
    public Field<Object> source() { return source; }

    public static CreateBrowserProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateBrowserProfileRequest");
        Builder builder = builder();
        Object rawBrowserProfile = Wire.optional(object, "browser_profile");
        if (!Wire.isMissing(rawBrowserProfile)) {
            builder.browserProfile(rawBrowserProfile == null ? null : Wire.string(rawBrowserProfile, "CreateBrowserProfileRequest.browser_profile"));
        }
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "CreateBrowserProfileRequest.color"));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "CreateBrowserProfileRequest.icon"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "CreateBrowserProfileRequest.index"));
        }
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "CreateBrowserProfileRequest.name"));
        Object rawSource = Wire.optional(object, "source");
        if (!Wire.isMissing(rawSource)) {
            builder.source(rawSource == null ? null : Wire.immutableJson(rawSource));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile", browserProfile);
        Wire.put(object, "color", color);
        Wire.put(object, "icon", icon);
        Wire.put(object, "index", index);
        Wire.put(object, "name", name);
        Wire.put(object, "source", source);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateBrowserProfileRequest that)) return false;
        return Objects.equals(browserProfile, that.browserProfile) && Objects.equals(color, that.color) && Objects.equals(icon, that.icon) && Objects.equals(index, that.index) && Objects.equals(name, that.name) && Objects.equals(source, that.source);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfile, color, icon, index, name, source); }

    @Override
    public String toString() { return "CreateBrowserProfileRequest" + toWire(); }

    public static final class Builder {
        private Field<String> browserProfile = Field.omitted();
        private Field<String> color = Field.omitted();
        private Field<String> icon = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private String name;
        private boolean nameSet;
        private Field<Object> source = Field.omitted();

        public Builder browserProfile(String value) {
            this.browserProfile = Field.ofNullable(value);
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
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder source(Object value) {
            this.source = Field.ofNullable(value);
            return this;
        }
        public CreateBrowserProfileRequest build() { return new CreateBrowserProfileRequest(this); }
    }
}

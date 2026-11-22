// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-personal-group request. Protocol v12; authority: control. */
public final class CreatePersonalGroupRequest implements WireValue {
    private final Field<Boolean> collapsed;
    private final Field<String> color;
    private final Field<String> group;
    private final Field<UInt64> index;
    private final String name;
    private final Field<String> profile;

    private CreatePersonalGroupRequest(Builder builder) {
        this.collapsed = builder.collapsed;
        this.color = builder.color;
        this.group = builder.group;
        this.index = builder.index;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.profile = builder.profile;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> collapsed() { return collapsed; }
    public Field<String> color() { return color; }
    public Field<String> group() { return group; }
    public Field<UInt64> index() { return index; }
    public String name() { return name; }
    public Field<String> profile() { return profile; }

    public static CreatePersonalGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreatePersonalGroupRequest");
        Builder builder = builder();
        Object rawCollapsed = Wire.optional(object, "collapsed");
        if (!Wire.isMissing(rawCollapsed)) {
            builder.collapsed(Wire.bool(rawCollapsed, "CreatePersonalGroupRequest.collapsed"));
        }
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "CreatePersonalGroupRequest.color"));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "CreatePersonalGroupRequest.group"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "CreatePersonalGroupRequest.index"));
        }
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "CreatePersonalGroupRequest.name"));
        Object rawProfile = Wire.optional(object, "profile");
        if (!Wire.isMissing(rawProfile)) {
            builder.profile(rawProfile == null ? null : Wire.string(rawProfile, "CreatePersonalGroupRequest.profile"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "collapsed", collapsed);
        Wire.put(object, "color", color);
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "name", name);
        Wire.put(object, "profile", profile);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreatePersonalGroupRequest that)) return false;
        return Objects.equals(collapsed, that.collapsed) && Objects.equals(color, that.color) && Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(name, that.name) && Objects.equals(profile, that.profile);
    }

    @Override
    public int hashCode() { return Objects.hash(collapsed, color, group, index, name, profile); }

    @Override
    public String toString() { return "CreatePersonalGroupRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> collapsed = Field.omitted();
        private Field<String> color = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private String name;
        private boolean nameSet;
        private Field<String> profile = Field.omitted();

        public Builder collapsed(Boolean value) {
            this.collapsed = Field.of(value);
            return this;
        }
        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
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
        public CreatePersonalGroupRequest build() { return new CreatePersonalGroupRequest(this); }
    }
}

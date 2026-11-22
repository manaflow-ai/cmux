// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-screen-group request. Protocol v12; authority: control. */
public final class CreateScreenGroupRequest implements WireValue {
    private final Field<String> color;
    private final Field<String> name;
    private final List<UInt64> screens;

    private CreateScreenGroupRequest(Builder builder) {
        this.color = builder.color;
        this.name = builder.name;
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> color() { return color; }
    public Field<String> name() { return name; }
    public List<UInt64> screens() { return screens; }

    public static CreateScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateScreenGroupRequest");
        Builder builder = builder();
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "CreateScreenGroupRequest.color"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "CreateScreenGroupRequest.name"));
        }
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "CreateScreenGroupRequest.screens", item -> Wire.uint64(item, "CreateScreenGroupRequest.screens item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "color", color);
        Wire.put(object, "name", name);
        Wire.put(object, "screens", screens);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateScreenGroupRequest that)) return false;
        return Objects.equals(color, that.color) && Objects.equals(name, that.name) && Objects.equals(screens, that.screens);
    }

    @Override
    public int hashCode() { return Objects.hash(color, name, screens); }

    @Override
    public String toString() { return "CreateScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private Field<String> color = Field.omitted();
        private Field<String> name = Field.omitted();
        private List<UInt64> screens;
        private boolean screensSet;

        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder screens(List<UInt64> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public CreateScreenGroupRequest build() { return new CreateScreenGroupRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable add-screens-to-screen-group request. Protocol v12; authority: control. */
public final class AddScreensToScreenGroupRequest implements WireValue {
    private final String group;
    private final Field<UInt64> index;
    private final List<UInt64> screens;

    private AddScreensToScreenGroupRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.index = builder.index;
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public Field<UInt64> index() { return index; }
    public List<UInt64> screens() { return screens; }

    public static AddScreensToScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AddScreensToScreenGroupRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "AddScreensToScreenGroupRequest.group"));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "AddScreensToScreenGroupRequest.index"));
        }
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "AddScreensToScreenGroupRequest.screens", item -> Wire.uint64(item, "AddScreensToScreenGroupRequest.screens item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "screens", screens);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AddScreensToScreenGroupRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(screens, that.screens);
    }

    @Override
    public int hashCode() { return Objects.hash(group, index, screens); }

    @Override
    public String toString() { return "AddScreensToScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private Field<UInt64> index = Field.omitted();
        private List<UInt64> screens;
        private boolean screensSet;

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder screens(List<UInt64> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public AddScreensToScreenGroupRequest build() { return new AddScreensToScreenGroupRequest(this); }
    }
}

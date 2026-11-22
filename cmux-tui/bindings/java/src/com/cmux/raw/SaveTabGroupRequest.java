// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable save-tab-group request. Protocol v12; authority: control. */
public final class SaveTabGroupRequest implements WireValue {
    private final String group;

    private SaveTabGroupRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }

    public static SaveTabGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SaveTabGroupRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "SaveTabGroupRequest.group"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SaveTabGroupRequest that)) return false;
        return Objects.equals(group, that.group);
    }

    @Override
    public int hashCode() { return Objects.hash(group); }

    @Override
    public String toString() { return "SaveTabGroupRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public SaveTabGroupRequest build() { return new SaveTabGroupRequest(this); }
    }
}

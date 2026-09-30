// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-personal-group request. Protocol v12; authority: control. */
public final class MovePersonalGroupRequest implements WireValue {
    private final String group;
    private final UInt64 index;

    private MovePersonalGroupRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public UInt64 index() { return index; }

    public static MovePersonalGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MovePersonalGroupRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "MovePersonalGroupRequest.group"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MovePersonalGroupRequest.index"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MovePersonalGroupRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(index, that.index);
    }

    @Override
    public int hashCode() { return Objects.hash(group, index); }

    @Override
    public String toString() { return "MovePersonalGroupRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private UInt64 index;
        private boolean indexSet;

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public MovePersonalGroupRequest build() { return new MovePersonalGroupRequest(this); }
    }
}

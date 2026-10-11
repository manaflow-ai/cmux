// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-screen-group request. Protocol v12; authority: control. */
public final class CloseScreenGroupRequest implements WireValue {
    private final Field<Boolean> endTerminals;
    private final String group;

    private CloseScreenGroupRequest(Builder builder) {
        this.endTerminals = builder.endTerminals;
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> endTerminals() { return endTerminals; }
    public String group() { return group; }

    public static CloseScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseScreenGroupRequest");
        Builder builder = builder();
        Object rawEndTerminals = Wire.optional(object, "end_terminals");
        if (!Wire.isMissing(rawEndTerminals)) {
            builder.endTerminals(Wire.bool(rawEndTerminals, "CloseScreenGroupRequest.end_terminals"));
        }
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "CloseScreenGroupRequest.group"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "end_terminals", endTerminals);
        Wire.put(object, "group", group);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseScreenGroupRequest that)) return false;
        return Objects.equals(endTerminals, that.endTerminals) && Objects.equals(group, that.group);
    }

    @Override
    public int hashCode() { return Objects.hash(endTerminals, group); }

    @Override
    public String toString() { return "CloseScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> endTerminals = Field.omitted();
        private String group;
        private boolean groupSet;

        public Builder endTerminals(Boolean value) {
            this.endTerminals = Field.of(value);
            return this;
        }
        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public CloseScreenGroupRequest build() { return new CloseScreenGroupRequest(this); }
    }
}

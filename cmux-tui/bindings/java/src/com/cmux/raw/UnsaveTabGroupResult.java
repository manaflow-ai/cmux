// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class UnsaveTabGroupResult implements WireValue {
    private final String group;
    private final boolean unsaved;
    private final Map<String, Object> additionalProperties;

    private UnsaveTabGroupResult(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        if (!builder.unsavedSet) throw new IllegalArgumentException("unsaved is required");
        this.unsaved = builder.unsaved;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public boolean unsaved() { return unsaved; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static UnsaveTabGroupResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UnsaveTabGroupResult");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "UnsaveTabGroupResult.group"));
        Object rawUnsaved = Wire.required(object, "unsaved");
        builder.unsaved(Wire.bool(rawUnsaved, "UnsaveTabGroupResult.unsaved"));
        List<String> known = List.of("group", "unsaved");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "unsaved", unsaved);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UnsaveTabGroupResult that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(unsaved, that.unsaved) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(group, unsaved, additionalProperties); }

    @Override
    public String toString() { return "UnsaveTabGroupResult" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private Boolean unsaved;
        private boolean unsavedSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder unsaved(boolean value) {
            this.unsaved = value;
            this.unsavedSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public UnsaveTabGroupResult build() { return new UnsaveTabGroupResult(this); }
    }
}

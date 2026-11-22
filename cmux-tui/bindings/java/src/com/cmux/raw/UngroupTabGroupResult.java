// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class UngroupTabGroupResult implements WireValue {
    private final String group;
    private final List<UInt64> surfaces;
    private final Map<String, Object> additionalProperties;

    private UngroupTabGroupResult(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public List<UInt64> surfaces() { return surfaces; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static UngroupTabGroupResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UngroupTabGroupResult");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "UngroupTabGroupResult.group"));
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "UngroupTabGroupResult.surfaces", item -> Wire.uint64(item, "UngroupTabGroupResult.surfaces item")));
        List<String> known = List.of("group", "surfaces");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "surfaces", surfaces);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UngroupTabGroupResult that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(surfaces, that.surfaces) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(group, surfaces, additionalProperties); }

    @Override
    public String toString() { return "UngroupTabGroupResult" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private List<UInt64> surfaces;
        private boolean surfacesSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder surfaces(List<UInt64> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public UngroupTabGroupResult build() { return new UngroupTabGroupResult(this); }
    }
}

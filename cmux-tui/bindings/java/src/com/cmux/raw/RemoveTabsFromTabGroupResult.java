// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RemoveTabsFromTabGroupResult implements WireValue {
    /** Ids of the groups the tabs left. */
    private final List<String> groups;
    private final List<UInt64> surfaces;
    private final Map<String, Object> additionalProperties;

    private RemoveTabsFromTabGroupResult(Builder builder) {
        if (!builder.groupsSet) throw new IllegalArgumentException("groups is required");
        this.groups = List.copyOf(Wire.nonNull(builder.groups, "groups"));
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> groups() { return groups; }
    public List<UInt64> surfaces() { return surfaces; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static RemoveTabsFromTabGroupResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RemoveTabsFromTabGroupResult");
        Builder builder = builder();
        Object rawGroups = Wire.required(object, "groups");
        builder.groups(Wire.array(rawGroups, "RemoveTabsFromTabGroupResult.groups", item -> Wire.string(item, "RemoveTabsFromTabGroupResult.groups item")));
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "RemoveTabsFromTabGroupResult.surfaces", item -> Wire.uint64(item, "RemoveTabsFromTabGroupResult.surfaces item")));
        List<String> known = List.of("groups", "surfaces");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "groups", groups);
        Wire.put(object, "surfaces", surfaces);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RemoveTabsFromTabGroupResult that)) return false;
        return Objects.equals(groups, that.groups) && Objects.equals(surfaces, that.surfaces) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(groups, surfaces, additionalProperties); }

    @Override
    public String toString() { return "RemoveTabsFromTabGroupResult" + toWire(); }

    public static final class Builder {
        private List<String> groups;
        private boolean groupsSet;
        private List<UInt64> surfaces;
        private boolean surfacesSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder groups(List<String> value) {
            this.groups = value;
            this.groupsSet = true;
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
        public RemoveTabsFromTabGroupResult build() { return new RemoveTabsFromTabGroupResult(this); }
    }
}

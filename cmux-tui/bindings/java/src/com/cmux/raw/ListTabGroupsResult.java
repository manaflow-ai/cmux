// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListTabGroupsResult implements WireValue {
    private final List<TabGroupRun> groups;
    private final Map<String, Object> additionalProperties;

    private ListTabGroupsResult(Builder builder) {
        if (!builder.groupsSet) throw new IllegalArgumentException("groups is required");
        this.groups = List.copyOf(Wire.nonNull(builder.groups, "groups"));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public List<TabGroupRun> groups() { return groups; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ListTabGroupsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListTabGroupsResult");
        Builder builder = builder();
        Object rawGroups = Wire.required(object, "groups");
        builder.groups(Wire.array(rawGroups, "ListTabGroupsResult.groups", item -> TabGroupRun.fromWire(item)));
        List<String> known = List.of("groups");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "groups", groups);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListTabGroupsResult that)) return false;
        return Objects.equals(groups, that.groups) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(groups, additionalProperties); }

    @Override
    public String toString() { return "ListTabGroupsResult" + toWire(); }

    public static final class Builder {
        private List<TabGroupRun> groups;
        private boolean groupsSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder groups(List<TabGroupRun> value) {
            this.groups = value;
            this.groupsSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ListTabGroupsResult build() { return new ListTabGroupsResult(this); }
    }
}

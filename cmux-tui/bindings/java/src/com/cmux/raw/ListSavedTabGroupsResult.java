// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListSavedTabGroupsResult implements WireValue {
    private final List<SavedTabGroupRecord> savedGroups;
    private final Map<String, Object> additionalProperties;

    private ListSavedTabGroupsResult(Builder builder) {
        if (!builder.savedGroupsSet) throw new IllegalArgumentException("saved_groups is required");
        this.savedGroups = List.copyOf(Wire.nonNull(builder.savedGroups, "saved_groups"));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public List<SavedTabGroupRecord> savedGroups() { return savedGroups; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ListSavedTabGroupsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListSavedTabGroupsResult");
        Builder builder = builder();
        Object rawSavedGroups = Wire.required(object, "saved_groups");
        builder.savedGroups(Wire.array(rawSavedGroups, "ListSavedTabGroupsResult.saved_groups", item -> SavedTabGroupRecord.fromWire(item)));
        List<String> known = List.of("saved_groups");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "saved_groups", savedGroups);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListSavedTabGroupsResult that)) return false;
        return Objects.equals(savedGroups, that.savedGroups) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(savedGroups, additionalProperties); }

    @Override
    public String toString() { return "ListSavedTabGroupsResult" + toWire(); }

    public static final class Builder {
        private List<SavedTabGroupRecord> savedGroups;
        private boolean savedGroupsSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder savedGroups(List<SavedTabGroupRecord> value) {
            this.savedGroups = value;
            this.savedGroupsSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ListSavedTabGroupsResult build() { return new ListSavedTabGroupsResult(this); }
    }
}

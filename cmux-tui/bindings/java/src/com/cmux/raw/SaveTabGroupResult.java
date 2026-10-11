// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SaveTabGroupResult implements WireValue {
    private final String group;
    private final String saved;
    private final Map<String, Object> additionalProperties;

    private SaveTabGroupResult(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        if (!builder.savedSet) throw new IllegalArgumentException("saved is required");
        this.saved = Wire.nonNull(builder.saved, "saved");
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public String saved() { return saved; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static SaveTabGroupResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SaveTabGroupResult");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "SaveTabGroupResult.group"));
        Object rawSaved = Wire.required(object, "saved");
        builder.saved(Wire.string(rawSaved, "SaveTabGroupResult.saved"));
        List<String> known = List.of("group", "saved");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "saved", saved);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SaveTabGroupResult that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(saved, that.saved) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(group, saved, additionalProperties); }

    @Override
    public String toString() { return "SaveTabGroupResult" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private String saved;
        private boolean savedSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder saved(String value) {
            this.saved = value;
            this.savedSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public SaveTabGroupResult build() { return new SaveTabGroupResult(this); }
    }
}

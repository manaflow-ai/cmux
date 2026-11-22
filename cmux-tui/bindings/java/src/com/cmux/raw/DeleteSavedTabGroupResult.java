// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class DeleteSavedTabGroupResult implements WireValue {
    private final boolean deleted;
    private final String saved;
    private final Map<String, Object> additionalProperties;

    private DeleteSavedTabGroupResult(Builder builder) {
        if (!builder.deletedSet) throw new IllegalArgumentException("deleted is required");
        this.deleted = builder.deleted;
        if (!builder.savedSet) throw new IllegalArgumentException("saved is required");
        this.saved = Wire.nonNull(builder.saved, "saved");
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public boolean deleted() { return deleted; }
    public String saved() { return saved; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static DeleteSavedTabGroupResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteSavedTabGroupResult");
        Builder builder = builder();
        Object rawDeleted = Wire.required(object, "deleted");
        builder.deleted(Wire.bool(rawDeleted, "DeleteSavedTabGroupResult.deleted"));
        Object rawSaved = Wire.required(object, "saved");
        builder.saved(Wire.string(rawSaved, "DeleteSavedTabGroupResult.saved"));
        List<String> known = List.of("deleted", "saved");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "deleted", deleted);
        Wire.put(object, "saved", saved);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteSavedTabGroupResult that)) return false;
        return Objects.equals(deleted, that.deleted) && Objects.equals(saved, that.saved) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(deleted, saved, additionalProperties); }

    @Override
    public String toString() { return "DeleteSavedTabGroupResult" + toWire(); }

    public static final class Builder {
        private Boolean deleted;
        private boolean deletedSet;
        private String saved;
        private boolean savedSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder deleted(boolean value) {
            this.deleted = value;
            this.deletedSet = true;
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
        public DeleteSavedTabGroupResult build() { return new DeleteSavedTabGroupResult(this); }
    }
}

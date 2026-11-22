// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class DeleteBookmarkResult implements WireValue {
    /** The deleted node's id first, then its descendants. */
    private final List<String> deleted;
    private final boolean replayed;
    private final Map<String, Object> additionalProperties;

    private DeleteBookmarkResult(Builder builder) {
        if (!builder.deletedSet) throw new IllegalArgumentException("deleted is required");
        this.deleted = List.copyOf(Wire.nonNull(builder.deleted, "deleted"));
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> deleted() { return deleted; }
    public boolean replayed() { return replayed; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static DeleteBookmarkResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteBookmarkResult");
        Builder builder = builder();
        Object rawDeleted = Wire.required(object, "deleted");
        builder.deleted(Wire.array(rawDeleted, "DeleteBookmarkResult.deleted", item -> Wire.string(item, "DeleteBookmarkResult.deleted item")));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "DeleteBookmarkResult.replayed"));
        List<String> known = List.of("deleted", "replayed");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "deleted", deleted);
        Wire.put(object, "replayed", replayed);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteBookmarkResult that)) return false;
        return Objects.equals(deleted, that.deleted) && Objects.equals(replayed, that.replayed) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(deleted, replayed, additionalProperties); }

    @Override
    public String toString() { return "DeleteBookmarkResult" + toWire(); }

    public static final class Builder {
        private List<String> deleted;
        private boolean deletedSet;
        private Boolean replayed;
        private boolean replayedSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder deleted(List<String> value) {
            this.deleted = value;
            this.deletedSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public DeleteBookmarkResult build() { return new DeleteBookmarkResult(this); }
    }
}

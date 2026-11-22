// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ImportBookmarksResult implements WireValue {
    /** Nodes in the request, descendants included. */
    private final UInt64 count;
    private final boolean replayed;
    /** Top-level nodes written; in replace mode the kept folder first. */
    private final List<String> rootIds;
    private final Map<String, Object> additionalProperties;

    private ImportBookmarksResult(Builder builder) {
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = Wire.nonNull(builder.count, "count");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.rootIdsSet) throw new IllegalArgumentException("root_ids is required");
        this.rootIds = List.copyOf(Wire.nonNull(builder.rootIds, "root_ids"));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 count() { return count; }
    public boolean replayed() { return replayed; }
    public List<String> rootIds() { return rootIds; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ImportBookmarksResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ImportBookmarksResult");
        Builder builder = builder();
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint64(rawCount, "ImportBookmarksResult.count"));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "ImportBookmarksResult.replayed"));
        Object rawRootIds = Wire.required(object, "root_ids");
        builder.rootIds(Wire.array(rawRootIds, "ImportBookmarksResult.root_ids", item -> Wire.string(item, "ImportBookmarksResult.root_ids item")));
        List<String> known = List.of("count", "replayed", "root_ids");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "count", count);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "root_ids", rootIds);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ImportBookmarksResult that)) return false;
        return Objects.equals(count, that.count) && Objects.equals(replayed, that.replayed) && Objects.equals(rootIds, that.rootIds) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(count, replayed, rootIds, additionalProperties); }

    @Override
    public String toString() { return "ImportBookmarksResult" + toWire(); }

    public static final class Builder {
        private UInt64 count;
        private boolean countSet;
        private Boolean replayed;
        private boolean replayedSet;
        private List<String> rootIds;
        private boolean rootIdsSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder count(UInt64 value) {
            this.count = value;
            this.countSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder rootIds(List<String> value) {
            this.rootIds = value;
            this.rootIdsSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ImportBookmarksResult build() { return new ImportBookmarksResult(this); }
    }
}

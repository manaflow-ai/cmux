// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MergeBookmarksResult implements WireValue {
    /** Nodes written. */
    private final UInt64 created;
    /** False when this merge_key was already merged for the profile: nothing changed. */
    private final boolean merged;
    private final boolean replayed;
    /** Chromium nodes cmux already had (same id, or same URL in the same folder), folders merged into one with the same title, and nodes refused by the limits. */
    private final UInt64 skipped;
    private final Map<String, Object> additionalProperties;

    private MergeBookmarksResult(Builder builder) {
        if (!builder.createdSet) throw new IllegalArgumentException("created is required");
        this.created = Wire.nonNull(builder.created, "created");
        if (!builder.mergedSet) throw new IllegalArgumentException("merged is required");
        this.merged = builder.merged;
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.skippedSet) throw new IllegalArgumentException("skipped is required");
        this.skipped = Wire.nonNull(builder.skipped, "skipped");
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 created() { return created; }
    public boolean merged() { return merged; }
    public boolean replayed() { return replayed; }
    public UInt64 skipped() { return skipped; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static MergeBookmarksResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MergeBookmarksResult");
        Builder builder = builder();
        Object rawCreated = Wire.required(object, "created");
        builder.created(Wire.uint64(rawCreated, "MergeBookmarksResult.created"));
        Object rawMerged = Wire.required(object, "merged");
        builder.merged(Wire.bool(rawMerged, "MergeBookmarksResult.merged"));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "MergeBookmarksResult.replayed"));
        Object rawSkipped = Wire.required(object, "skipped");
        builder.skipped(Wire.uint64(rawSkipped, "MergeBookmarksResult.skipped"));
        List<String> known = List.of("created", "merged", "replayed", "skipped");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "created", created);
        Wire.put(object, "merged", merged);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "skipped", skipped);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MergeBookmarksResult that)) return false;
        return Objects.equals(created, that.created) && Objects.equals(merged, that.merged) && Objects.equals(replayed, that.replayed) && Objects.equals(skipped, that.skipped) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(created, merged, replayed, skipped, additionalProperties); }

    @Override
    public String toString() { return "MergeBookmarksResult" + toWire(); }

    public static final class Builder {
        private UInt64 created;
        private boolean createdSet;
        private Boolean merged;
        private boolean mergedSet;
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 skipped;
        private boolean skippedSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder created(UInt64 value) {
            this.created = value;
            this.createdSet = true;
            return this;
        }
        public Builder merged(boolean value) {
            this.merged = value;
            this.mergedSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder skipped(UInt64 value) {
            this.skipped = value;
            this.skippedSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public MergeBookmarksResult build() { return new MergeBookmarksResult(this); }
    }
}

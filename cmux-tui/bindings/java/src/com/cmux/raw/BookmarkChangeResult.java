// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BookmarkChangeResult implements WireValue {
    private final Bookmark bookmark;
    private final boolean changed;
    private final boolean replayed;
    private final Map<String, Object> additionalProperties;

    private BookmarkChangeResult(Builder builder) {
        if (!builder.bookmarkSet) throw new IllegalArgumentException("bookmark is required");
        this.bookmark = Wire.nonNull(builder.bookmark, "bookmark");
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = builder.changed;
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Bookmark bookmark() { return bookmark; }
    public boolean changed() { return changed; }
    public boolean replayed() { return replayed; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static BookmarkChangeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BookmarkChangeResult");
        Builder builder = builder();
        Object rawBookmark = Wire.required(object, "bookmark");
        builder.bookmark(Bookmark.fromWire(rawBookmark));
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.bool(rawChanged, "BookmarkChangeResult.changed"));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "BookmarkChangeResult.replayed"));
        List<String> known = List.of("bookmark", "changed", "replayed");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        Wire.put(object, "changed", changed);
        Wire.put(object, "replayed", replayed);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BookmarkChangeResult that)) return false;
        return Objects.equals(bookmark, that.bookmark) && Objects.equals(changed, that.changed) && Objects.equals(replayed, that.replayed) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark, changed, replayed, additionalProperties); }

    @Override
    public String toString() { return "BookmarkChangeResult" + toWire(); }

    public static final class Builder {
        private Bookmark bookmark;
        private boolean bookmarkSet;
        private Boolean changed;
        private boolean changedSet;
        private Boolean replayed;
        private boolean replayedSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder bookmark(Bookmark value) {
            this.bookmark = value;
            this.bookmarkSet = true;
            return this;
        }
        public Builder changed(boolean value) {
            this.changed = value;
            this.changedSet = true;
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
        public BookmarkChangeResult build() { return new BookmarkChangeResult(this); }
    }
}

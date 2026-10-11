// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListBookmarksResult implements WireValue {
    /** The whole tree in depth-first pre-order: the bar tree, then the other tree. */
    private final List<Bookmark> bookmarks;
    private final UInt64 bookmarksRevision;
    private final Map<String, Object> additionalProperties;

    private ListBookmarksResult(Builder builder) {
        if (!builder.bookmarksSet) throw new IllegalArgumentException("bookmarks is required");
        this.bookmarks = List.copyOf(Wire.nonNull(builder.bookmarks, "bookmarks"));
        if (!builder.bookmarksRevisionSet) throw new IllegalArgumentException("bookmarks_revision is required");
        this.bookmarksRevision = Wire.nonNull(builder.bookmarksRevision, "bookmarks_revision");
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public List<Bookmark> bookmarks() { return bookmarks; }
    public UInt64 bookmarksRevision() { return bookmarksRevision; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ListBookmarksResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListBookmarksResult");
        Builder builder = builder();
        Object rawBookmarks = Wire.required(object, "bookmarks");
        builder.bookmarks(Wire.array(rawBookmarks, "ListBookmarksResult.bookmarks", item -> Bookmark.fromWire(item)));
        Object rawBookmarksRevision = Wire.required(object, "bookmarks_revision");
        builder.bookmarksRevision(Wire.uint64(rawBookmarksRevision, "ListBookmarksResult.bookmarks_revision"));
        List<String> known = List.of("bookmarks", "bookmarks_revision");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmarks", bookmarks);
        Wire.put(object, "bookmarks_revision", bookmarksRevision);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListBookmarksResult that)) return false;
        return Objects.equals(bookmarks, that.bookmarks) && Objects.equals(bookmarksRevision, that.bookmarksRevision) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmarks, bookmarksRevision, additionalProperties); }

    @Override
    public String toString() { return "ListBookmarksResult" + toWire(); }

    public static final class Builder {
        private List<Bookmark> bookmarks;
        private boolean bookmarksSet;
        private UInt64 bookmarksRevision;
        private boolean bookmarksRevisionSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder bookmarks(List<Bookmark> value) {
            this.bookmarks = value;
            this.bookmarksSet = true;
            return this;
        }
        public Builder bookmarksRevision(UInt64 value) {
            this.bookmarksRevision = value;
            this.bookmarksRevisionSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ListBookmarksResult build() { return new ListBookmarksResult(this); }
    }
}

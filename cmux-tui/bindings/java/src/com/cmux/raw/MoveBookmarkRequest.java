// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-bookmark request. Protocol v12; authority: control. */
public final class MoveBookmarkRequest implements WireValue {
    private final String bookmark;
    private final UInt64 index;
    private final String parent;

    private MoveBookmarkRequest(Builder builder) {
        if (!builder.bookmarkSet) throw new IllegalArgumentException("bookmark is required");
        this.bookmark = Wire.nonNull(builder.bookmark, "bookmark");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.parentSet) throw new IllegalArgumentException("parent is required");
        this.parent = Wire.nonNull(builder.parent, "parent");
    }

    public static Builder builder() { return new Builder(); }

    public String bookmark() { return bookmark; }
    public UInt64 index() { return index; }
    public String parent() { return parent; }

    public static MoveBookmarkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveBookmarkRequest");
        Builder builder = builder();
        Object rawBookmark = Wire.required(object, "bookmark");
        builder.bookmark(Wire.string(rawBookmark, "MoveBookmarkRequest.bookmark"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MoveBookmarkRequest.index"));
        Object rawParent = Wire.required(object, "parent");
        builder.parent(Wire.string(rawParent, "MoveBookmarkRequest.parent"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        Wire.put(object, "index", index);
        Wire.put(object, "parent", parent);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveBookmarkRequest that)) return false;
        return Objects.equals(bookmark, that.bookmark) && Objects.equals(index, that.index) && Objects.equals(parent, that.parent);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark, index, parent); }

    @Override
    public String toString() { return "MoveBookmarkRequest" + toWire(); }

    public static final class Builder {
        private String bookmark;
        private boolean bookmarkSet;
        private UInt64 index;
        private boolean indexSet;
        private String parent;
        private boolean parentSet;

        public Builder bookmark(String value) {
            this.bookmark = value;
            this.bookmarkSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder parent(String value) {
            this.parent = value;
            this.parentSet = true;
            return this;
        }
        public MoveBookmarkRequest build() { return new MoveBookmarkRequest(this); }
    }
}

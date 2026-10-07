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
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final String parent;

    private MoveBookmarkRequest(Builder builder) {
        if (!builder.bookmarkSet) throw new IllegalArgumentException("bookmark is required");
        this.bookmark = Wire.nonNull(builder.bookmark, "bookmark");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.parentSet) throw new IllegalArgumentException("parent is required");
        this.parent = Wire.nonNull(builder.parent, "parent");
    }

    public static Builder builder() { return new Builder(); }

    public String bookmark() { return bookmark; }
    public UInt64 index() { return index; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public String parent() { return parent; }

    public static MoveBookmarkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveBookmarkRequest");
        Builder builder = builder();
        Object rawBookmark = Wire.required(object, "bookmark");
        builder.bookmark(Wire.string(rawBookmark, "MoveBookmarkRequest.bookmark"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MoveBookmarkRequest.index"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "MoveBookmarkRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "MoveBookmarkRequest.origin"));
        }
        Object rawParent = Wire.required(object, "parent");
        builder.parent(Wire.string(rawParent, "MoveBookmarkRequest.parent"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        Wire.put(object, "index", index);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "parent", parent);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveBookmarkRequest that)) return false;
        return Objects.equals(bookmark, that.bookmark) && Objects.equals(index, that.index) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(parent, that.parent);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark, index, mutationId, origin, parent); }

    @Override
    public String toString() { return "MoveBookmarkRequest" + toWire(); }

    public static final class Builder {
        private String bookmark;
        private boolean bookmarkSet;
        private UInt64 index;
        private boolean indexSet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
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
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
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

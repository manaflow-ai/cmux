// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable delete-bookmark request. Protocol v12; authority: control. */
public final class DeleteBookmarkRequest implements WireValue {
    private final String bookmark;
    private final Field<String> mutationId;
    private final Field<String> origin;

    private DeleteBookmarkRequest(Builder builder) {
        if (!builder.bookmarkSet) throw new IllegalArgumentException("bookmark is required");
        this.bookmark = Wire.nonNull(builder.bookmark, "bookmark");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public String bookmark() { return bookmark; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }

    public static DeleteBookmarkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteBookmarkRequest");
        Builder builder = builder();
        Object rawBookmark = Wire.required(object, "bookmark");
        builder.bookmark(Wire.string(rawBookmark, "DeleteBookmarkRequest.bookmark"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "DeleteBookmarkRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "DeleteBookmarkRequest.origin"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteBookmarkRequest that)) return false;
        return Objects.equals(bookmark, that.bookmark) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark, mutationId, origin); }

    @Override
    public String toString() { return "DeleteBookmarkRequest" + toWire(); }

    public static final class Builder {
        private String bookmark;
        private boolean bookmarkSet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();

        public Builder bookmark(String value) {
            this.bookmark = value;
            this.bookmarkSet = true;
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
        public DeleteBookmarkRequest build() { return new DeleteBookmarkRequest(this); }
    }
}

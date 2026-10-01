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

    private DeleteBookmarkRequest(Builder builder) {
        if (!builder.bookmarkSet) throw new IllegalArgumentException("bookmark is required");
        this.bookmark = Wire.nonNull(builder.bookmark, "bookmark");
    }

    public static Builder builder() { return new Builder(); }

    public String bookmark() { return bookmark; }

    public static DeleteBookmarkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteBookmarkRequest");
        Builder builder = builder();
        Object rawBookmark = Wire.required(object, "bookmark");
        builder.bookmark(Wire.string(rawBookmark, "DeleteBookmarkRequest.bookmark"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteBookmarkRequest that)) return false;
        return Objects.equals(bookmark, that.bookmark);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark); }

    @Override
    public String toString() { return "DeleteBookmarkRequest" + toWire(); }

    public static final class Builder {
        private String bookmark;
        private boolean bookmarkSet;

        public Builder bookmark(String value) {
            this.bookmark = value;
            this.bookmarkSet = true;
            return this;
        }
        public DeleteBookmarkRequest build() { return new DeleteBookmarkRequest(this); }
    }
}

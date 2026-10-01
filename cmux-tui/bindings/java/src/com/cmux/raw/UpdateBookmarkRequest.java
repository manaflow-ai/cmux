// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable update-bookmark request. Protocol v12; authority: control. */
public final class UpdateBookmarkRequest implements WireValue {
    private final String bookmark;
    private final Field<String> faviconKey;
    private final Field<UInt64> lastUsedMs;
    private final Field<String> title;
    private final Field<String> url;

    private UpdateBookmarkRequest(Builder builder) {
        if (!builder.bookmarkSet) throw new IllegalArgumentException("bookmark is required");
        this.bookmark = Wire.nonNull(builder.bookmark, "bookmark");
        this.faviconKey = builder.faviconKey;
        this.lastUsedMs = builder.lastUsedMs;
        this.title = builder.title;
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public String bookmark() { return bookmark; }
    public Field<String> faviconKey() { return faviconKey; }
    public Field<UInt64> lastUsedMs() { return lastUsedMs; }
    public Field<String> title() { return title; }
    public Field<String> url() { return url; }

    public static UpdateBookmarkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UpdateBookmarkRequest");
        Builder builder = builder();
        Object rawBookmark = Wire.required(object, "bookmark");
        builder.bookmark(Wire.string(rawBookmark, "UpdateBookmarkRequest.bookmark"));
        Object rawFaviconKey = Wire.optional(object, "favicon_key");
        if (!Wire.isMissing(rawFaviconKey)) {
            builder.faviconKey(rawFaviconKey == null ? null : Wire.string(rawFaviconKey, "UpdateBookmarkRequest.favicon_key"));
        }
        Object rawLastUsedMs = Wire.optional(object, "last_used_ms");
        if (!Wire.isMissing(rawLastUsedMs)) {
            builder.lastUsedMs(rawLastUsedMs == null ? null : Wire.uint64(rawLastUsedMs, "UpdateBookmarkRequest.last_used_ms"));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "UpdateBookmarkRequest.title"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "UpdateBookmarkRequest.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        Wire.put(object, "favicon_key", faviconKey);
        Wire.put(object, "last_used_ms", lastUsedMs);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UpdateBookmarkRequest that)) return false;
        return Objects.equals(bookmark, that.bookmark) && Objects.equals(faviconKey, that.faviconKey) && Objects.equals(lastUsedMs, that.lastUsedMs) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark, faviconKey, lastUsedMs, title, url); }

    @Override
    public String toString() { return "UpdateBookmarkRequest" + toWire(); }

    public static final class Builder {
        private String bookmark;
        private boolean bookmarkSet;
        private Field<String> faviconKey = Field.omitted();
        private Field<UInt64> lastUsedMs = Field.omitted();
        private Field<String> title = Field.omitted();
        private Field<String> url = Field.omitted();

        public Builder bookmark(String value) {
            this.bookmark = value;
            this.bookmarkSet = true;
            return this;
        }
        public Builder faviconKey(String value) {
            this.faviconKey = Field.ofNullable(value);
            return this;
        }
        public Builder lastUsedMs(UInt64 value) {
            this.lastUsedMs = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.ofNullable(value);
            return this;
        }
        public Builder url(String value) {
            this.url = Field.ofNullable(value);
            return this;
        }
        public UpdateBookmarkRequest build() { return new UpdateBookmarkRequest(this); }
    }
}

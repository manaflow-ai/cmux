// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-bookmark request. Protocol v12; authority: control. */
public final class CreateBookmarkRequest implements WireValue {
    private final Field<String> bookmark;
    private final String browserProfileId;
    private final Field<UInt64> createdMs;
    private final Field<String> faviconKey;
    private final Field<UInt64> index;
    private final String kind;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final String parent;
    private final Field<String> sourceKey;
    private final String title;
    private final Field<String> url;

    private CreateBookmarkRequest(Builder builder) {
        this.bookmark = builder.bookmark;
        if (!builder.browserProfileIdSet) throw new IllegalArgumentException("browser_profile_id is required");
        this.browserProfileId = Wire.nonNull(builder.browserProfileId, "browser_profile_id");
        this.createdMs = builder.createdMs;
        this.faviconKey = builder.faviconKey;
        this.index = builder.index;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.parentSet) throw new IllegalArgumentException("parent is required");
        this.parent = Wire.nonNull(builder.parent, "parent");
        this.sourceKey = builder.sourceKey;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> bookmark() { return bookmark; }
    public String browserProfileId() { return browserProfileId; }
    public Field<UInt64> createdMs() { return createdMs; }
    public Field<String> faviconKey() { return faviconKey; }
    public Field<UInt64> index() { return index; }
    public String kind() { return kind; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public String parent() { return parent; }
    public Field<String> sourceKey() { return sourceKey; }
    public String title() { return title; }
    public Field<String> url() { return url; }

    public static CreateBookmarkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateBookmarkRequest");
        Builder builder = builder();
        Object rawBookmark = Wire.optional(object, "bookmark");
        if (!Wire.isMissing(rawBookmark)) {
            builder.bookmark(rawBookmark == null ? null : Wire.string(rawBookmark, "CreateBookmarkRequest.bookmark"));
        }
        Object rawBrowserProfileId = Wire.required(object, "browser_profile_id");
        builder.browserProfileId(Wire.string(rawBrowserProfileId, "CreateBookmarkRequest.browser_profile_id"));
        Object rawCreatedMs = Wire.optional(object, "created_ms");
        if (!Wire.isMissing(rawCreatedMs)) {
            builder.createdMs(rawCreatedMs == null ? null : Wire.uint64(rawCreatedMs, "CreateBookmarkRequest.created_ms"));
        }
        Object rawFaviconKey = Wire.optional(object, "favicon_key");
        if (!Wire.isMissing(rawFaviconKey)) {
            builder.faviconKey(rawFaviconKey == null ? null : Wire.string(rawFaviconKey, "CreateBookmarkRequest.favicon_key"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "CreateBookmarkRequest.index"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "CreateBookmarkRequest.kind"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "CreateBookmarkRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CreateBookmarkRequest.origin"));
        }
        Object rawParent = Wire.required(object, "parent");
        builder.parent(Wire.string(rawParent, "CreateBookmarkRequest.parent"));
        Object rawSourceKey = Wire.optional(object, "source_key");
        if (!Wire.isMissing(rawSourceKey)) {
            builder.sourceKey(rawSourceKey == null ? null : Wire.string(rawSourceKey, "CreateBookmarkRequest.source_key"));
        }
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "CreateBookmarkRequest.title"));
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "CreateBookmarkRequest.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bookmark", bookmark);
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "created_ms", createdMs);
        Wire.put(object, "favicon_key", faviconKey);
        Wire.put(object, "index", index);
        Wire.put(object, "kind", kind);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "parent", parent);
        Wire.put(object, "source_key", sourceKey);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateBookmarkRequest that)) return false;
        return Objects.equals(bookmark, that.bookmark) && Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(createdMs, that.createdMs) && Objects.equals(faviconKey, that.faviconKey) && Objects.equals(index, that.index) && Objects.equals(kind, that.kind) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(parent, that.parent) && Objects.equals(sourceKey, that.sourceKey) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmark, browserProfileId, createdMs, faviconKey, index, kind, mutationId, origin, parent, sourceKey, title, url); }

    @Override
    public String toString() { return "CreateBookmarkRequest" + toWire(); }

    public static final class Builder {
        private Field<String> bookmark = Field.omitted();
        private String browserProfileId;
        private boolean browserProfileIdSet;
        private Field<UInt64> createdMs = Field.omitted();
        private Field<String> faviconKey = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private String kind;
        private boolean kindSet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private String parent;
        private boolean parentSet;
        private Field<String> sourceKey = Field.omitted();
        private String title;
        private boolean titleSet;
        private Field<String> url = Field.omitted();

        public Builder bookmark(String value) {
            this.bookmark = Field.ofNullable(value);
            return this;
        }
        public Builder browserProfileId(String value) {
            this.browserProfileId = value;
            this.browserProfileIdSet = true;
            return this;
        }
        public Builder createdMs(UInt64 value) {
            this.createdMs = Field.ofNullable(value);
            return this;
        }
        public Builder faviconKey(String value) {
            this.faviconKey = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
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
        public Builder sourceKey(String value) {
            this.sourceKey = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder url(String value) {
            this.url = Field.ofNullable(value);
            return this;
        }
        public CreateBookmarkRequest build() { return new CreateBookmarkRequest(this); }
    }
}

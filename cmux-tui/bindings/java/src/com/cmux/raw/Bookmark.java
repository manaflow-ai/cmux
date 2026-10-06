// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Bookmark implements WireValue {
    private final String browserProfileId;
    private final UInt64 createdMs;
    private final Field<String> faviconKey;
    /** `bm_` and 32 lowercase hex digits. */
    private final String id;
    /** Dense 0-based position among the node's siblings. */
    private final UInt64 index;
    /** Known values: url, folder. Other values are future kinds. */
    private final String kind;
    private final Field<UInt64> lastUsedMs;
    /** `bar`, `other`, or a folder's id. */
    private final String parent;
    /** Folders only. */
    private final Field<String> sourceKey;
    private final String title;
    /** url nodes. */
    private final Field<String> url;
    private final Map<String, Object> additionalProperties;

    private Bookmark(Builder builder) {
        if (!builder.browserProfileIdSet) throw new IllegalArgumentException("browser_profile_id is required");
        this.browserProfileId = Wire.nonNull(builder.browserProfileId, "browser_profile_id");
        if (!builder.createdMsSet) throw new IllegalArgumentException("created_ms is required");
        this.createdMs = Wire.nonNull(builder.createdMs, "created_ms");
        this.faviconKey = builder.faviconKey;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.lastUsedMs = builder.lastUsedMs;
        if (!builder.parentSet) throw new IllegalArgumentException("parent is required");
        this.parent = Wire.nonNull(builder.parent, "parent");
        this.sourceKey = builder.sourceKey;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        this.url = builder.url;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfileId() { return browserProfileId; }
    public UInt64 createdMs() { return createdMs; }
    public Field<String> faviconKey() { return faviconKey; }
    public String id() { return id; }
    public UInt64 index() { return index; }
    public String kind() { return kind; }
    public Field<UInt64> lastUsedMs() { return lastUsedMs; }
    public String parent() { return parent; }
    public Field<String> sourceKey() { return sourceKey; }
    public String title() { return title; }
    public Field<String> url() { return url; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static Bookmark fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Bookmark");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.required(object, "browser_profile_id");
        builder.browserProfileId(Wire.string(rawBrowserProfileId, "Bookmark.browser_profile_id"));
        Object rawCreatedMs = Wire.required(object, "created_ms");
        builder.createdMs(Wire.uint64(rawCreatedMs, "Bookmark.created_ms"));
        Object rawFaviconKey = Wire.optional(object, "favicon_key");
        if (!Wire.isMissing(rawFaviconKey)) {
            builder.faviconKey(Wire.string(rawFaviconKey, "Bookmark.favicon_key"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "Bookmark.id"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "Bookmark.index"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "Bookmark.kind"));
        Object rawLastUsedMs = Wire.optional(object, "last_used_ms");
        if (!Wire.isMissing(rawLastUsedMs)) {
            builder.lastUsedMs(Wire.uint64(rawLastUsedMs, "Bookmark.last_used_ms"));
        }
        Object rawParent = Wire.required(object, "parent");
        builder.parent(Wire.string(rawParent, "Bookmark.parent"));
        Object rawSourceKey = Wire.optional(object, "source_key");
        if (!Wire.isMissing(rawSourceKey)) {
            builder.sourceKey(Wire.string(rawSourceKey, "Bookmark.source_key"));
        }
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "Bookmark.title"));
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(Wire.string(rawUrl, "Bookmark.url"));
        }
        List<String> known = List.of("browser_profile_id", "created_ms", "favicon_key", "id", "index", "kind", "last_used_ms", "parent", "source_key", "title", "url");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "created_ms", createdMs);
        Wire.put(object, "favicon_key", faviconKey);
        Wire.put(object, "id", id);
        Wire.put(object, "index", index);
        Wire.put(object, "kind", kind);
        Wire.put(object, "last_used_ms", lastUsedMs);
        Wire.put(object, "parent", parent);
        Wire.put(object, "source_key", sourceKey);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Bookmark that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(createdMs, that.createdMs) && Objects.equals(faviconKey, that.faviconKey) && Objects.equals(id, that.id) && Objects.equals(index, that.index) && Objects.equals(kind, that.kind) && Objects.equals(lastUsedMs, that.lastUsedMs) && Objects.equals(parent, that.parent) && Objects.equals(sourceKey, that.sourceKey) && Objects.equals(title, that.title) && Objects.equals(url, that.url) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId, createdMs, faviconKey, id, index, kind, lastUsedMs, parent, sourceKey, title, url, additionalProperties); }

    @Override
    public String toString() { return "Bookmark" + toWire(); }

    public static final class Builder {
        private String browserProfileId;
        private boolean browserProfileIdSet;
        private UInt64 createdMs;
        private boolean createdMsSet;
        private Field<String> faviconKey = Field.omitted();
        private String id;
        private boolean idSet;
        private UInt64 index;
        private boolean indexSet;
        private String kind;
        private boolean kindSet;
        private Field<UInt64> lastUsedMs = Field.omitted();
        private String parent;
        private boolean parentSet;
        private Field<String> sourceKey = Field.omitted();
        private String title;
        private boolean titleSet;
        private Field<String> url = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder browserProfileId(String value) {
            this.browserProfileId = value;
            this.browserProfileIdSet = true;
            return this;
        }
        public Builder createdMs(UInt64 value) {
            this.createdMs = value;
            this.createdMsSet = true;
            return this;
        }
        public Builder faviconKey(String value) {
            this.faviconKey = Field.of(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder lastUsedMs(UInt64 value) {
            this.lastUsedMs = Field.of(value);
            return this;
        }
        public Builder parent(String value) {
            this.parent = value;
            this.parentSet = true;
            return this;
        }
        public Builder sourceKey(String value) {
            this.sourceKey = Field.of(value);
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder url(String value) {
            this.url = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public Bookmark build() { return new Bookmark(this); }
    }
}

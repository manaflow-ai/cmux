// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BookmarkImportNode implements WireValue {
    /** A folder's nodes. */
    private final Field<List<BookmarkImportNode>> children;
    /** Defaults to now. */
    private final Field<UInt64> createdMs;
    /** url or folder. */
    private final String kind;
    private final String title;
    /** Required for a url node; refused for a folder. */
    private final Field<String> url;

    private BookmarkImportNode(Builder builder) {
        this.children = builder.children.map(value -> List.copyOf(value));
        this.createdMs = builder.createdMs;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<BookmarkImportNode>> children() { return children; }
    public Field<UInt64> createdMs() { return createdMs; }
    public String kind() { return kind; }
    public String title() { return title; }
    public Field<String> url() { return url; }

    public static BookmarkImportNode fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BookmarkImportNode");
        Builder builder = builder();
        Object rawChildren = Wire.optional(object, "children");
        if (!Wire.isMissing(rawChildren)) {
            builder.children(Wire.array(rawChildren, "BookmarkImportNode.children", item -> BookmarkImportNode.fromWire(item)));
        }
        Object rawCreatedMs = Wire.optional(object, "created_ms");
        if (!Wire.isMissing(rawCreatedMs)) {
            builder.createdMs(Wire.uint64(rawCreatedMs, "BookmarkImportNode.created_ms"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "BookmarkImportNode.kind"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "BookmarkImportNode.title"));
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(Wire.string(rawUrl, "BookmarkImportNode.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "children", children);
        Wire.put(object, "created_ms", createdMs);
        Wire.put(object, "kind", kind);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BookmarkImportNode that)) return false;
        return Objects.equals(children, that.children) && Objects.equals(createdMs, that.createdMs) && Objects.equals(kind, that.kind) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(children, createdMs, kind, title, url); }

    @Override
    public String toString() { return "BookmarkImportNode" + toWire(); }

    public static final class Builder {
        private Field<List<BookmarkImportNode>> children = Field.omitted();
        private Field<UInt64> createdMs = Field.omitted();
        private String kind;
        private boolean kindSet;
        private String title;
        private boolean titleSet;
        private Field<String> url = Field.omitted();

        public Builder children(List<BookmarkImportNode> value) {
            this.children = Field.of(value);
            return this;
        }
        public Builder createdMs(UInt64 value) {
            this.createdMs = Field.of(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
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
        public BookmarkImportNode build() { return new BookmarkImportNode(this); }
    }
}

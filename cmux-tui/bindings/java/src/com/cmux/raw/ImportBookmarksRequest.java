// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable import-bookmarks request. Protocol v12; authority: control. */
public final class ImportBookmarksRequest implements WireValue {
    private final String browserProfileId;
    private final Field<UInt64> index;
    private final Field<String> mutationId;
    private final List<Object> nodes;
    private final Field<String> origin;
    private final String parent;
    private final Field<Boolean> replace;
    private final Field<String> sourceKey;

    private ImportBookmarksRequest(Builder builder) {
        if (!builder.browserProfileIdSet) throw new IllegalArgumentException("browser_profile_id is required");
        this.browserProfileId = Wire.nonNull(builder.browserProfileId, "browser_profile_id");
        this.index = builder.index;
        this.mutationId = builder.mutationId;
        if (!builder.nodesSet) throw new IllegalArgumentException("nodes is required");
        this.nodes = List.copyOf(Wire.nonNull(builder.nodes, "nodes"));
        this.origin = builder.origin;
        if (!builder.parentSet) throw new IllegalArgumentException("parent is required");
        this.parent = Wire.nonNull(builder.parent, "parent");
        this.replace = builder.replace;
        this.sourceKey = builder.sourceKey;
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfileId() { return browserProfileId; }
    public Field<UInt64> index() { return index; }
    public Field<String> mutationId() { return mutationId; }
    public List<Object> nodes() { return nodes; }
    public Field<String> origin() { return origin; }
    public String parent() { return parent; }
    public Field<Boolean> replace() { return replace; }
    public Field<String> sourceKey() { return sourceKey; }

    public static ImportBookmarksRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ImportBookmarksRequest");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.required(object, "browser_profile_id");
        builder.browserProfileId(Wire.string(rawBrowserProfileId, "ImportBookmarksRequest.browser_profile_id"));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "ImportBookmarksRequest.index"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "ImportBookmarksRequest.mutation_id"));
        }
        Object rawNodes = Wire.required(object, "nodes");
        builder.nodes(Wire.array(rawNodes, "ImportBookmarksRequest.nodes", item -> Wire.immutableJson(item)));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "ImportBookmarksRequest.origin"));
        }
        Object rawParent = Wire.required(object, "parent");
        builder.parent(Wire.string(rawParent, "ImportBookmarksRequest.parent"));
        Object rawReplace = Wire.optional(object, "replace");
        if (!Wire.isMissing(rawReplace)) {
            builder.replace(Wire.bool(rawReplace, "ImportBookmarksRequest.replace"));
        }
        Object rawSourceKey = Wire.optional(object, "source_key");
        if (!Wire.isMissing(rawSourceKey)) {
            builder.sourceKey(rawSourceKey == null ? null : Wire.string(rawSourceKey, "ImportBookmarksRequest.source_key"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "index", index);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "nodes", nodes);
        Wire.put(object, "origin", origin);
        Wire.put(object, "parent", parent);
        Wire.put(object, "replace", replace);
        Wire.put(object, "source_key", sourceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ImportBookmarksRequest that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(index, that.index) && Objects.equals(mutationId, that.mutationId) && Objects.equals(nodes, that.nodes) && Objects.equals(origin, that.origin) && Objects.equals(parent, that.parent) && Objects.equals(replace, that.replace) && Objects.equals(sourceKey, that.sourceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId, index, mutationId, nodes, origin, parent, replace, sourceKey); }

    @Override
    public String toString() { return "ImportBookmarksRequest" + toWire(); }

    public static final class Builder {
        private String browserProfileId;
        private boolean browserProfileIdSet;
        private Field<UInt64> index = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private List<Object> nodes;
        private boolean nodesSet;
        private Field<String> origin = Field.omitted();
        private String parent;
        private boolean parentSet;
        private Field<Boolean> replace = Field.omitted();
        private Field<String> sourceKey = Field.omitted();

        public Builder browserProfileId(String value) {
            this.browserProfileId = value;
            this.browserProfileIdSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder nodes(List<Object> value) {
            this.nodes = value;
            this.nodesSet = true;
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
        public Builder replace(Boolean value) {
            this.replace = Field.of(value);
            return this;
        }
        public Builder sourceKey(String value) {
            this.sourceKey = Field.ofNullable(value);
            return this;
        }
        public ImportBookmarksRequest build() { return new ImportBookmarksRequest(this); }
    }
}

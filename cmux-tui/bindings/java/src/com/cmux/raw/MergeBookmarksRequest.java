// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable merge-bookmarks request. Protocol v12; authority: control. */
public final class MergeBookmarksRequest implements WireValue {
    private final String browserProfileId;
    private final String chromiumBookmarks;
    private final String mergeKey;
    private final Field<String> mutationId;
    private final Field<String> origin;

    private MergeBookmarksRequest(Builder builder) {
        if (!builder.browserProfileIdSet) throw new IllegalArgumentException("browser_profile_id is required");
        this.browserProfileId = Wire.nonNull(builder.browserProfileId, "browser_profile_id");
        if (!builder.chromiumBookmarksSet) throw new IllegalArgumentException("chromium_bookmarks is required");
        this.chromiumBookmarks = Wire.nonNull(builder.chromiumBookmarks, "chromium_bookmarks");
        if (!builder.mergeKeySet) throw new IllegalArgumentException("merge_key is required");
        this.mergeKey = Wire.nonNull(builder.mergeKey, "merge_key");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfileId() { return browserProfileId; }
    public String chromiumBookmarks() { return chromiumBookmarks; }
    public String mergeKey() { return mergeKey; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }

    public static MergeBookmarksRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MergeBookmarksRequest");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.required(object, "browser_profile_id");
        builder.browserProfileId(Wire.string(rawBrowserProfileId, "MergeBookmarksRequest.browser_profile_id"));
        Object rawChromiumBookmarks = Wire.required(object, "chromium_bookmarks");
        builder.chromiumBookmarks(Wire.string(rawChromiumBookmarks, "MergeBookmarksRequest.chromium_bookmarks"));
        Object rawMergeKey = Wire.required(object, "merge_key");
        builder.mergeKey(Wire.string(rawMergeKey, "MergeBookmarksRequest.merge_key"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "MergeBookmarksRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "MergeBookmarksRequest.origin"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "chromium_bookmarks", chromiumBookmarks);
        Wire.put(object, "merge_key", mergeKey);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MergeBookmarksRequest that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(chromiumBookmarks, that.chromiumBookmarks) && Objects.equals(mergeKey, that.mergeKey) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId, chromiumBookmarks, mergeKey, mutationId, origin); }

    @Override
    public String toString() { return "MergeBookmarksRequest" + toWire(); }

    public static final class Builder {
        private String browserProfileId;
        private boolean browserProfileIdSet;
        private String chromiumBookmarks;
        private boolean chromiumBookmarksSet;
        private String mergeKey;
        private boolean mergeKeySet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();

        public Builder browserProfileId(String value) {
            this.browserProfileId = value;
            this.browserProfileIdSet = true;
            return this;
        }
        public Builder chromiumBookmarks(String value) {
            this.chromiumBookmarks = value;
            this.chromiumBookmarksSet = true;
            return this;
        }
        public Builder mergeKey(String value) {
            this.mergeKey = value;
            this.mergeKeySet = true;
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
        public MergeBookmarksRequest build() { return new MergeBookmarksRequest(this); }
    }
}

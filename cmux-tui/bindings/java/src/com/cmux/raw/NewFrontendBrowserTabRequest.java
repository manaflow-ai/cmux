// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-frontend-browser-tab request. Protocol v12; authority: control. */
public final class NewFrontendBrowserTabRequest implements WireValue {
    private final Field<Integer> cols;
    private final String engine;
    private final Field<String> faviconUrl;
    private final Field<String> idempotencyKey;
    private final Field<String> owner;
    private final Field<UInt64> pane;
    private final Field<String> profileId;
    private final Field<Integer> rows;
    private final Field<String> title;
    private final String url;

    private NewFrontendBrowserTabRequest(Builder builder) {
        this.cols = builder.cols;
        if (!builder.engineSet) throw new IllegalArgumentException("engine is required");
        this.engine = Wire.nonNull(builder.engine, "engine");
        this.faviconUrl = builder.faviconUrl;
        this.idempotencyKey = builder.idempotencyKey;
        this.owner = builder.owner;
        this.pane = builder.pane;
        this.profileId = builder.profileId;
        this.rows = builder.rows;
        this.title = builder.title;
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public String engine() { return engine; }
    public Field<String> faviconUrl() { return faviconUrl; }
    public Field<String> idempotencyKey() { return idempotencyKey; }
    public Field<String> owner() { return owner; }
    public Field<UInt64> pane() { return pane; }
    public Field<String> profileId() { return profileId; }
    public Field<Integer> rows() { return rows; }
    public Field<String> title() { return title; }
    public String url() { return url; }

    public static NewFrontendBrowserTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewFrontendBrowserTabRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewFrontendBrowserTabRequest.cols"));
        }
        Object rawEngine = Wire.required(object, "engine");
        builder.engine(Wire.string(rawEngine, "NewFrontendBrowserTabRequest.engine"));
        Object rawFaviconUrl = Wire.optional(object, "favicon_url");
        if (!Wire.isMissing(rawFaviconUrl)) {
            builder.faviconUrl(rawFaviconUrl == null ? null : Wire.string(rawFaviconUrl, "NewFrontendBrowserTabRequest.favicon_url"));
        }
        Object rawIdempotencyKey = Wire.optional(object, "idempotency_key");
        if (!Wire.isMissing(rawIdempotencyKey)) {
            builder.idempotencyKey(rawIdempotencyKey == null ? null : Wire.string(rawIdempotencyKey, "NewFrontendBrowserTabRequest.idempotency_key"));
        }
        Object rawOwner = Wire.optional(object, "owner");
        if (!Wire.isMissing(rawOwner)) {
            builder.owner(rawOwner == null ? null : Wire.string(rawOwner, "NewFrontendBrowserTabRequest.owner"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewFrontendBrowserTabRequest.pane"));
        }
        Object rawProfileId = Wire.optional(object, "profile_id");
        if (!Wire.isMissing(rawProfileId)) {
            builder.profileId(rawProfileId == null ? null : Wire.string(rawProfileId, "NewFrontendBrowserTabRequest.profile_id"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewFrontendBrowserTabRequest.rows"));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "NewFrontendBrowserTabRequest.title"));
        }
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "NewFrontendBrowserTabRequest.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "engine", engine);
        Wire.put(object, "favicon_url", faviconUrl);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "owner", owner);
        Wire.put(object, "pane", pane);
        Wire.put(object, "profile_id", profileId);
        Wire.put(object, "rows", rows);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewFrontendBrowserTabRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(engine, that.engine) && Objects.equals(faviconUrl, that.faviconUrl) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(owner, that.owner) && Objects.equals(pane, that.pane) && Objects.equals(profileId, that.profileId) && Objects.equals(rows, that.rows) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, engine, faviconUrl, idempotencyKey, owner, pane, profileId, rows, title, url); }

    @Override
    public String toString() { return "NewFrontendBrowserTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private String engine;
        private boolean engineSet;
        private Field<String> faviconUrl = Field.omitted();
        private Field<String> idempotencyKey = Field.omitted();
        private Field<String> owner = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<String> profileId = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<String> title = Field.omitted();
        private String url;
        private boolean urlSet;

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder engine(String value) {
            this.engine = value;
            this.engineSet = true;
            return this;
        }
        public Builder faviconUrl(String value) {
            this.faviconUrl = Field.ofNullable(value);
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = Field.ofNullable(value);
            return this;
        }
        public Builder owner(String value) {
            this.owner = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder profileId(String value) {
            this.profileId = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.ofNullable(value);
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public NewFrontendBrowserTabRequest build() { return new NewFrontendBrowserTabRequest(this); }
    }
}

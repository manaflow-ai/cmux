// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class WorkspaceFirstTabBrowser implements WireValue, WorkspaceFirstTab {
    private final Field<Boolean> activate;
    private final Field<Integer> cols;
    private final String engine;
    private final Field<String> faviconUrl;
    private final Field<String> idempotencyKey;
    private final Field<String> owner;
    private final Field<String> profileId;
    private final Field<Integer> rows;
    private final Field<String> title;
    private final String url;

    private WorkspaceFirstTabBrowser(Builder builder) {
        this.activate = builder.activate;
        this.cols = builder.cols;
        if (!builder.engineSet) throw new IllegalArgumentException("engine is required");
        this.engine = Wire.nonNull(builder.engine, "engine");
        this.faviconUrl = builder.faviconUrl;
        this.idempotencyKey = builder.idempotencyKey;
        this.owner = builder.owner;
        this.profileId = builder.profileId;
        this.rows = builder.rows;
        this.title = builder.title;
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public Field<Integer> cols() { return cols; }
    public String engine() { return engine; }
    public Field<String> faviconUrl() { return faviconUrl; }
    public Field<String> idempotencyKey() { return idempotencyKey; }
    public String kind() { return "browser"; }
    public Field<String> owner() { return owner; }
    public Field<String> profileId() { return profileId; }
    public Field<Integer> rows() { return rows; }
    public Field<String> title() { return title; }
    public String url() { return url; }

    public static WorkspaceFirstTabBrowser fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspaceFirstTabBrowser");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(Wire.bool(rawActivate, "WorkspaceFirstTabBrowser.activate"));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "WorkspaceFirstTabBrowser.cols"));
        }
        Object rawEngine = Wire.required(object, "engine");
        builder.engine(Wire.string(rawEngine, "WorkspaceFirstTabBrowser.engine"));
        Object rawFaviconUrl = Wire.optional(object, "favicon_url");
        if (!Wire.isMissing(rawFaviconUrl)) {
            builder.faviconUrl(rawFaviconUrl == null ? null : Wire.string(rawFaviconUrl, "WorkspaceFirstTabBrowser.favicon_url"));
        }
        Object rawIdempotencyKey = Wire.optional(object, "idempotency_key");
        if (!Wire.isMissing(rawIdempotencyKey)) {
            builder.idempotencyKey(rawIdempotencyKey == null ? null : Wire.string(rawIdempotencyKey, "WorkspaceFirstTabBrowser.idempotency_key"));
        }
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "browser", "WorkspaceFirstTabBrowser.kind");
        Object rawOwner = Wire.optional(object, "owner");
        if (!Wire.isMissing(rawOwner)) {
            builder.owner(rawOwner == null ? null : Wire.string(rawOwner, "WorkspaceFirstTabBrowser.owner"));
        }
        Object rawProfileId = Wire.optional(object, "profile_id");
        if (!Wire.isMissing(rawProfileId)) {
            builder.profileId(rawProfileId == null ? null : Wire.string(rawProfileId, "WorkspaceFirstTabBrowser.profile_id"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "WorkspaceFirstTabBrowser.rows"));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "WorkspaceFirstTabBrowser.title"));
        }
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "WorkspaceFirstTabBrowser.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "cols", cols);
        Wire.put(object, "engine", engine);
        Wire.put(object, "favicon_url", faviconUrl);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "kind", "browser");
        Wire.put(object, "owner", owner);
        Wire.put(object, "profile_id", profileId);
        Wire.put(object, "rows", rows);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WorkspaceFirstTabBrowser that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(cols, that.cols) && Objects.equals(engine, that.engine) && Objects.equals(faviconUrl, that.faviconUrl) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(owner, that.owner) && Objects.equals(profileId, that.profileId) && Objects.equals(rows, that.rows) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, cols, engine, faviconUrl, idempotencyKey, owner, profileId, rows, title, url); }

    @Override
    public String toString() { return "WorkspaceFirstTabBrowser" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private String engine;
        private boolean engineSet;
        private Field<String> faviconUrl = Field.omitted();
        private Field<String> idempotencyKey = Field.omitted();
        private Field<String> owner = Field.omitted();
        private Field<String> profileId = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<String> title = Field.omitted();
        private String url;
        private boolean urlSet;

        public Builder activate(Boolean value) {
            this.activate = Field.of(value);
            return this;
        }
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
        public WorkspaceFirstTabBrowser build() { return new WorkspaceFirstTabBrowser(this); }
    }
}

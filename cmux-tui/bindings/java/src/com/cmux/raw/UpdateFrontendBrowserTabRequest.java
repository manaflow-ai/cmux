// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable update-frontend-browser-tab request. Protocol v12; authority: control. */
public final class UpdateFrontendBrowserTabRequest implements WireValue {
    private final Field<String> faviconUrl;
    private final UInt64 surface;
    private final Field<String> title;
    private final Field<String> url;

    private UpdateFrontendBrowserTabRequest(Builder builder) {
        this.faviconUrl = builder.faviconUrl;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.title = builder.title;
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> faviconUrl() { return faviconUrl; }
    public UInt64 surface() { return surface; }
    public Field<String> title() { return title; }
    public Field<String> url() { return url; }

    public static UpdateFrontendBrowserTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UpdateFrontendBrowserTabRequest");
        Builder builder = builder();
        Object rawFaviconUrl = Wire.optional(object, "favicon_url");
        if (!Wire.isMissing(rawFaviconUrl)) {
            builder.faviconUrl(rawFaviconUrl == null ? null : Wire.string(rawFaviconUrl, "UpdateFrontendBrowserTabRequest.favicon_url"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "UpdateFrontendBrowserTabRequest.surface"));
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "UpdateFrontendBrowserTabRequest.title"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "UpdateFrontendBrowserTabRequest.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "favicon_url", faviconUrl);
        Wire.put(object, "surface", surface);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UpdateFrontendBrowserTabRequest that)) return false;
        return Objects.equals(faviconUrl, that.faviconUrl) && Objects.equals(surface, that.surface) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(faviconUrl, surface, title, url); }

    @Override
    public String toString() { return "UpdateFrontendBrowserTabRequest" + toWire(); }

    public static final class Builder {
        private Field<String> faviconUrl = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> title = Field.omitted();
        private Field<String> url = Field.omitted();

        public Builder faviconUrl(String value) {
            this.faviconUrl = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
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
        public UpdateFrontendBrowserTabRequest build() { return new UpdateFrontendBrowserTabRequest(this); }
    }
}

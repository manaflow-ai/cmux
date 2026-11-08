// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-navigate request. Protocol v6; authority: frontend. */
public final class BrowserNavigateRequest implements WireValue {
    private final UInt64 surface;
    private final String url;

    private BrowserNavigateRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public String url() { return url; }

    public static BrowserNavigateRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserNavigateRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserNavigateRequest.surface"));
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "BrowserNavigateRequest.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserNavigateRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, url); }

    @Override
    public String toString() { return "BrowserNavigateRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private String url;
        private boolean urlSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public BrowserNavigateRequest build() { return new BrowserNavigateRequest(this); }
    }
}

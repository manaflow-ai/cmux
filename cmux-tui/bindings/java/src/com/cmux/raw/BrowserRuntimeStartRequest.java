// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-runtime-start request. Protocol v12; authority: local-admin. */
public final class BrowserRuntimeStartRequest implements WireValue {
    private final Field<String> url;

    private BrowserRuntimeStartRequest(Builder builder) {
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> url() { return url; }

    public static BrowserRuntimeStartRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserRuntimeStartRequest");
        Builder builder = builder();
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "BrowserRuntimeStartRequest.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserRuntimeStartRequest that)) return false;
        return Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(url); }

    @Override
    public String toString() { return "BrowserRuntimeStartRequest" + toWire(); }

    public static final class Builder {
        private Field<String> url = Field.omitted();

        public Builder url(String value) {
            this.url = Field.ofNullable(value);
            return this;
        }
        public BrowserRuntimeStartRequest build() { return new BrowserRuntimeStartRequest(this); }
    }
}

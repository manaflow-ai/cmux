// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-link-resolve request. Protocol v12; authority: local-admin. */
public final class ConversationLinkResolveRequest implements WireValue {
    private final String url;

    private ConversationLinkResolveRequest(Builder builder) {
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public String url() { return url; }

    public static ConversationLinkResolveRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationLinkResolveRequest");
        Builder builder = builder();
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "ConversationLinkResolveRequest.url"));
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
        if (!(other instanceof ConversationLinkResolveRequest that)) return false;
        return Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(url); }

    @Override
    public String toString() { return "ConversationLinkResolveRequest" + toWire(); }

    public static final class Builder {
        private String url;
        private boolean urlSet;

        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public ConversationLinkResolveRequest build() { return new ConversationLinkResolveRequest(this); }
    }
}

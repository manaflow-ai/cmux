// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable url-open request. Protocol v12; authority: local-admin. */
public final class UrlOpenRequest implements WireValue {
    private final String terminalId;
    private final String url;

    private UrlOpenRequest(Builder builder) {
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public String terminalId() { return terminalId; }
    public String url() { return url; }

    public static UrlOpenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UrlOpenRequest");
        Builder builder = builder();
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "UrlOpenRequest.terminal_id"));
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "UrlOpenRequest.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UrlOpenRequest that)) return false;
        return Objects.equals(terminalId, that.terminalId) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(terminalId, url); }

    @Override
    public String toString() { return "UrlOpenRequest" + toWire(); }

    public static final class Builder {
        private String terminalId;
        private boolean terminalIdSet;
        private String url;
        private boolean urlSet;

        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public UrlOpenRequest build() { return new UrlOpenRequest(this); }
    }
}

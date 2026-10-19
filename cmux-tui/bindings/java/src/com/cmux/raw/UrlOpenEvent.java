// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable url-open event. Protocol v12; streams: control. */
public final class UrlOpenEvent implements WireValue, ProtocolEvent {
    private final String requestId;
    private final String terminalId;
    private final String url;

    private UrlOpenEvent(Builder builder) {
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public String requestId() { return requestId; }
    public String terminalId() { return terminalId; }
    public String url() { return url; }
    @Override public String event() { return "url-open"; }

    public static UrlOpenEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UrlOpenEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "url-open", "UrlOpenEvent.event");
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "UrlOpenEvent.request_id"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "UrlOpenEvent.terminal_id"));
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "UrlOpenEvent.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "url-open");
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UrlOpenEvent that)) return false;
        return Objects.equals(requestId, that.requestId) && Objects.equals(terminalId, that.terminalId) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(requestId, terminalId, url); }

    @Override
    public String toString() { return "UrlOpenEvent" + toWire(); }

    public static final class Builder {
        private String requestId;
        private boolean requestIdSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String url;
        private boolean urlSet;

        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
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
        public UrlOpenEvent build() { return new UrlOpenEvent(this); }
    }
}

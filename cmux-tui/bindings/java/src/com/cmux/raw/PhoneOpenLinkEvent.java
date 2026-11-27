// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable phone-open-link event. Protocol v12; streams: control. */
public final class PhoneOpenLinkEvent implements WireValue, ProtocolEvent {
    private final String terminalId;
    private final String url;

    private PhoneOpenLinkEvent(Builder builder) {
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public String terminalId() { return terminalId; }
    public String url() { return url; }
    @Override public String event() { return "phone-open-link"; }

    public static PhoneOpenLinkEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PhoneOpenLinkEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "phone-open-link", "PhoneOpenLinkEvent.event");
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "PhoneOpenLinkEvent.terminal_id"));
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "PhoneOpenLinkEvent.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "phone-open-link");
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PhoneOpenLinkEvent that)) return false;
        return Objects.equals(terminalId, that.terminalId) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(terminalId, url); }

    @Override
    public String toString() { return "PhoneOpenLinkEvent" + toWire(); }

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
        public PhoneOpenLinkEvent build() { return new PhoneOpenLinkEvent(this); }
    }
}

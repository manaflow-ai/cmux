// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-clipboard-read event. Protocol v12; streams: control. */
public final class TerminalClipboardReadEvent implements WireValue, ProtocolEvent {
    private final TerminalClipboardHost host;
    private final TerminalClipboardLocation location;
    private final String requestId;
    private final String terminalId;

    private TerminalClipboardReadEvent(Builder builder) {
        if (!builder.hostSet) throw new IllegalArgumentException("host is required");
        this.host = Wire.nonNull(builder.host, "host");
        if (!builder.locationSet) throw new IllegalArgumentException("location is required");
        this.location = Wire.nonNull(builder.location, "location");
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public TerminalClipboardHost host() { return host; }
    public TerminalClipboardLocation location() { return location; }
    public String requestId() { return requestId; }
    public String terminalId() { return terminalId; }
    @Override public String event() { return "terminal-clipboard-read"; }

    public static TerminalClipboardReadEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalClipboardReadEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-clipboard-read", "TerminalClipboardReadEvent.event");
        Object rawHost = Wire.required(object, "host");
        builder.host(TerminalClipboardHost.fromWire(rawHost));
        Object rawLocation = Wire.required(object, "location");
        builder.location(TerminalClipboardLocation.fromWire(rawLocation));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "TerminalClipboardReadEvent.request_id"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalClipboardReadEvent.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-clipboard-read");
        Wire.put(object, "host", host);
        Wire.put(object, "location", location);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalClipboardReadEvent that)) return false;
        return Objects.equals(host, that.host) && Objects.equals(location, that.location) && Objects.equals(requestId, that.requestId) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(host, location, requestId, terminalId); }

    @Override
    public String toString() { return "TerminalClipboardReadEvent" + toWire(); }

    public static final class Builder {
        private TerminalClipboardHost host;
        private boolean hostSet;
        private TerminalClipboardLocation location;
        private boolean locationSet;
        private String requestId;
        private boolean requestIdSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder host(TerminalClipboardHost value) {
            this.host = value;
            this.hostSet = true;
            return this;
        }
        public Builder location(TerminalClipboardLocation value) {
            this.location = value;
            this.locationSet = true;
            return this;
        }
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
        public TerminalClipboardReadEvent build() { return new TerminalClipboardReadEvent(this); }
    }
}

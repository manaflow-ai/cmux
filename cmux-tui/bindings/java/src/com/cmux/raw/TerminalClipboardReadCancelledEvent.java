// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-clipboard-read-cancelled event. Protocol v12; streams: control. */
public final class TerminalClipboardReadCancelledEvent implements WireValue, ProtocolEvent {
    private final String requestId;

    private TerminalClipboardReadCancelledEvent(Builder builder) {
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
    }

    public static Builder builder() { return new Builder(); }

    public String requestId() { return requestId; }
    @Override public String event() { return "terminal-clipboard-read-cancelled"; }

    public static TerminalClipboardReadCancelledEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalClipboardReadCancelledEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-clipboard-read-cancelled", "TerminalClipboardReadCancelledEvent.event");
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "TerminalClipboardReadCancelledEvent.request_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-clipboard-read-cancelled");
        Wire.put(object, "request_id", requestId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalClipboardReadCancelledEvent that)) return false;
        return Objects.equals(requestId, that.requestId);
    }

    @Override
    public int hashCode() { return Objects.hash(requestId); }

    @Override
    public String toString() { return "TerminalClipboardReadCancelledEvent" + toWire(); }

    public static final class Builder {
        private String requestId;
        private boolean requestIdSet;

        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public TerminalClipboardReadCancelledEvent build() { return new TerminalClipboardReadCancelledEvent(this); }
    }
}

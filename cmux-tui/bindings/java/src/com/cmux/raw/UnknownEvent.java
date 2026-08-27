// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public final class UnknownEvent implements SubscribeEvent, DeltaStreamEvent, ByteAttachEvent, RenderAttachEvent, BrowserAttachEvent {
    private final String event;
    private final Map<String, Object> raw;
    @SuppressWarnings("unchecked")
    private UnknownEvent(String event, Map<String, Object> raw) {
        this.event = event;
        this.raw = (Map<String, Object>) Wire.immutableJson(raw);
    }
    public static UnknownEvent fromWire(Object value) {
        Map<String, Object> raw = Wire.object(value, "unknown event");
        return new UnknownEvent(Wire.string(Wire.required(raw, "event"), "unknown event.event"), raw);
    }
    @Override public String event() { return event; }
    public Map<String, Object> raw() { return raw; }
    @Override public Map<String, Object> toWire() { return raw; }
}

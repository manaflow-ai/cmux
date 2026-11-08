// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable window-title-requested event. Protocol v6; streams: subscribe. */
public final class WindowTitleRequestedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String title;

    private WindowTitleRequestedEvent(Builder builder) {
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String title() { return title; }
    @Override public String event() { return "window-title-requested"; }

    public static WindowTitleRequestedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WindowTitleRequestedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "window-title-requested", "WindowTitleRequestedEvent.event");
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "WindowTitleRequestedEvent.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "window-title-requested");
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WindowTitleRequestedEvent that)) return false;
        return Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(title); }

    @Override
    public String toString() { return "WindowTitleRequestedEvent" + toWire(); }

    public static final class Builder {
        private String title;
        private boolean titleSet;

        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public WindowTitleRequestedEvent build() { return new WindowTitleRequestedEvent(this); }
    }
}

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
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String title;

    private WindowTitleRequestedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public String title() { return title; }
    @Override public String event() { return "window-title-requested"; }

    public static WindowTitleRequestedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WindowTitleRequestedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "window-title-requested", "WindowTitleRequestedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "WindowTitleRequestedEvent.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "window-title-requested");
        Wire.put(object, "cause", cause);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WindowTitleRequestedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, title); }

    @Override
    public String toString() { return "WindowTitleRequestedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private String title;
        private boolean titleSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public WindowTitleRequestedEvent build() { return new WindowTitleRequestedEvent(this); }
    }
}

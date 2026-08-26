// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable journal-frontend-event request. Protocol v10; authority: control. */
public final class JournalFrontendEventRequest implements WireValue {
    private final FrontendJournalEvent event;

    private JournalFrontendEventRequest(Builder builder) {
        if (!builder.eventSet) throw new IllegalArgumentException("event is required");
        this.event = Wire.nonNull(builder.event, "event");
    }

    public static Builder builder() { return new Builder(); }

    public FrontendJournalEvent event() { return event; }

    public static JournalFrontendEventRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "JournalFrontendEventRequest");
        Builder builder = builder();
        Object rawEvent = Wire.required(object, "event");
        builder.event(FrontendJournalEvent.fromWire(rawEvent));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "event", event);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof JournalFrontendEventRequest that)) return false;
        return Objects.equals(event, that.event);
    }

    @Override
    public int hashCode() { return Objects.hash(event); }

    @Override
    public String toString() { return "JournalFrontendEventRequest" + toWire(); }

    public static final class Builder {
        private FrontendJournalEvent event;
        private boolean eventSet;

        public Builder event(FrontendJournalEvent value) {
            this.event = value;
            this.eventSet = true;
            return this;
        }
        public JournalFrontendEventRequest build() { return new JournalFrontendEventRequest(this); }
    }
}

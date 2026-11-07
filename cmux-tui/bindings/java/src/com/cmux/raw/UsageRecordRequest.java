// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable usage-record request. Protocol v12; authority: local-admin. */
public final class UsageRecordRequest implements WireValue {
    private final String events;
    private final String source;

    private UsageRecordRequest(Builder builder) {
        if (!builder.eventsSet) throw new IllegalArgumentException("events is required");
        this.events = Wire.nonNull(builder.events, "events");
        if (!builder.sourceSet) throw new IllegalArgumentException("source is required");
        this.source = Wire.nonNull(builder.source, "source");
    }

    public static Builder builder() { return new Builder(); }

    public String events() { return events; }
    public String source() { return source; }

    public static UsageRecordRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UsageRecordRequest");
        Builder builder = builder();
        Object rawEvents = Wire.required(object, "events");
        builder.events(Wire.string(rawEvents, "UsageRecordRequest.events"));
        Object rawSource = Wire.required(object, "source");
        builder.source(Wire.string(rawSource, "UsageRecordRequest.source"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "events", events);
        Wire.put(object, "source", source);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UsageRecordRequest that)) return false;
        return Objects.equals(events, that.events) && Objects.equals(source, that.source);
    }

    @Override
    public int hashCode() { return Objects.hash(events, source); }

    @Override
    public String toString() { return "UsageRecordRequest" + toWire(); }

    public static final class Builder {
        private String events;
        private boolean eventsSet;
        private String source;
        private boolean sourceSet;

        public Builder events(String value) {
            this.events = value;
            this.eventsSet = true;
            return this;
        }
        public Builder source(String value) {
            this.source = value;
            this.sourceSet = true;
            return this;
        }
        public UsageRecordRequest build() { return new UsageRecordRequest(this); }
    }
}

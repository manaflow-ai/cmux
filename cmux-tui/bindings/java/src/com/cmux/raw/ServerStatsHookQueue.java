// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsHookQueue implements WireValue {
    private final UInt64 queuedEvents;
    private final UInt64 resetDroppedEvents;
    private final UInt64 undeliverableEvents;

    private ServerStatsHookQueue(Builder builder) {
        if (!builder.queuedEventsSet) throw new IllegalArgumentException("queued_events is required");
        this.queuedEvents = Wire.nonNull(builder.queuedEvents, "queued_events");
        if (!builder.resetDroppedEventsSet) throw new IllegalArgumentException("reset_dropped_events is required");
        this.resetDroppedEvents = Wire.nonNull(builder.resetDroppedEvents, "reset_dropped_events");
        if (!builder.undeliverableEventsSet) throw new IllegalArgumentException("undeliverable_events is required");
        this.undeliverableEvents = Wire.nonNull(builder.undeliverableEvents, "undeliverable_events");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 queuedEvents() { return queuedEvents; }
    public UInt64 resetDroppedEvents() { return resetDroppedEvents; }
    public UInt64 undeliverableEvents() { return undeliverableEvents; }

    public static ServerStatsHookQueue fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsHookQueue");
        Builder builder = builder();
        Object rawQueuedEvents = Wire.required(object, "queued_events");
        builder.queuedEvents(Wire.uint64(rawQueuedEvents, "ServerStatsHookQueue.queued_events"));
        Object rawResetDroppedEvents = Wire.required(object, "reset_dropped_events");
        builder.resetDroppedEvents(Wire.uint64(rawResetDroppedEvents, "ServerStatsHookQueue.reset_dropped_events"));
        Object rawUndeliverableEvents = Wire.required(object, "undeliverable_events");
        builder.undeliverableEvents(Wire.uint64(rawUndeliverableEvents, "ServerStatsHookQueue.undeliverable_events"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "queued_events", queuedEvents);
        Wire.put(object, "reset_dropped_events", resetDroppedEvents);
        Wire.put(object, "undeliverable_events", undeliverableEvents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsHookQueue that)) return false;
        return Objects.equals(queuedEvents, that.queuedEvents) && Objects.equals(resetDroppedEvents, that.resetDroppedEvents) && Objects.equals(undeliverableEvents, that.undeliverableEvents);
    }

    @Override
    public int hashCode() { return Objects.hash(queuedEvents, resetDroppedEvents, undeliverableEvents); }

    @Override
    public String toString() { return "ServerStatsHookQueue" + toWire(); }

    public static final class Builder {
        private UInt64 queuedEvents;
        private boolean queuedEventsSet;
        private UInt64 resetDroppedEvents;
        private boolean resetDroppedEventsSet;
        private UInt64 undeliverableEvents;
        private boolean undeliverableEventsSet;

        public Builder queuedEvents(UInt64 value) {
            this.queuedEvents = value;
            this.queuedEventsSet = true;
            return this;
        }
        public Builder resetDroppedEvents(UInt64 value) {
            this.resetDroppedEvents = value;
            this.resetDroppedEventsSet = true;
            return this;
        }
        public Builder undeliverableEvents(UInt64 value) {
            this.undeliverableEvents = value;
            this.undeliverableEventsSet = true;
            return this;
        }
        public ServerStatsHookQueue build() { return new ServerStatsHookQueue(this); }
    }
}

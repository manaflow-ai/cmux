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

    private ServerStatsHookQueue(Builder builder) {
        if (!builder.queuedEventsSet) throw new IllegalArgumentException("queued_events is required");
        this.queuedEvents = Wire.nonNull(builder.queuedEvents, "queued_events");
        if (!builder.resetDroppedEventsSet) throw new IllegalArgumentException("reset_dropped_events is required");
        this.resetDroppedEvents = Wire.nonNull(builder.resetDroppedEvents, "reset_dropped_events");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 queuedEvents() { return queuedEvents; }
    public UInt64 resetDroppedEvents() { return resetDroppedEvents; }

    public static ServerStatsHookQueue fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsHookQueue");
        Builder builder = builder();
        Object rawQueuedEvents = Wire.required(object, "queued_events");
        builder.queuedEvents(Wire.uint64(rawQueuedEvents, "ServerStatsHookQueue.queued_events"));
        Object rawResetDroppedEvents = Wire.required(object, "reset_dropped_events");
        builder.resetDroppedEvents(Wire.uint64(rawResetDroppedEvents, "ServerStatsHookQueue.reset_dropped_events"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "queued_events", queuedEvents);
        Wire.put(object, "reset_dropped_events", resetDroppedEvents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsHookQueue that)) return false;
        return Objects.equals(queuedEvents, that.queuedEvents) && Objects.equals(resetDroppedEvents, that.resetDroppedEvents);
    }

    @Override
    public int hashCode() { return Objects.hash(queuedEvents, resetDroppedEvents); }

    @Override
    public String toString() { return "ServerStatsHookQueue" + toWire(); }

    public static final class Builder {
        private UInt64 queuedEvents;
        private boolean queuedEventsSet;
        private UInt64 resetDroppedEvents;
        private boolean resetDroppedEventsSet;

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
        public ServerStatsHookQueue build() { return new ServerStatsHookQueue(this); }
    }
}

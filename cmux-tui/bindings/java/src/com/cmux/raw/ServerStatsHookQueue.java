// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsHookQueue implements WireValue {
    private final UInt64 endedSessionEvents;

    private ServerStatsHookQueue(Builder builder) {
        if (!builder.endedSessionEventsSet) throw new IllegalArgumentException("ended_session_events is required");
        this.endedSessionEvents = Wire.nonNull(builder.endedSessionEvents, "ended_session_events");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 endedSessionEvents() { return endedSessionEvents; }

    public static ServerStatsHookQueue fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsHookQueue");
        Builder builder = builder();
        Object rawEndedSessionEvents = Wire.required(object, "ended_session_events");
        builder.endedSessionEvents(Wire.uint64(rawEndedSessionEvents, "ServerStatsHookQueue.ended_session_events"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ended_session_events", endedSessionEvents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsHookQueue that)) return false;
        return Objects.equals(endedSessionEvents, that.endedSessionEvents);
    }

    @Override
    public int hashCode() { return Objects.hash(endedSessionEvents); }

    @Override
    public String toString() { return "ServerStatsHookQueue" + toWire(); }

    public static final class Builder {
        private UInt64 endedSessionEvents;
        private boolean endedSessionEventsSet;

        public Builder endedSessionEvents(UInt64 value) {
            this.endedSessionEvents = value;
            this.endedSessionEventsSet = true;
            return this;
        }
        public ServerStatsHookQueue build() { return new ServerStatsHookQueue(this); }
    }
}

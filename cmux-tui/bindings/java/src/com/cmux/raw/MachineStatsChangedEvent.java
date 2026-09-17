// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable machine-stats-changed event. Protocol v12; streams: subscribe. */
public final class MachineStatsChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final MachineStats stats;

    private MachineStatsChangedEvent(Builder builder) {
        if (!builder.statsSet) throw new IllegalArgumentException("stats is required");
        this.stats = builder.stats;
    }

    public static Builder builder() { return new Builder(); }

    public MachineStats stats() { return stats; }
    @Override public String event() { return "machine-stats-changed"; }

    public static MachineStatsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineStatsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "machine-stats-changed", "MachineStatsChangedEvent.event");
        Object rawStats = Wire.required(object, "stats");
        builder.stats(rawStats == null ? null : MachineStats.fromWire(rawStats));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "machine-stats-changed");
        Wire.put(object, "stats", stats);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineStatsChangedEvent that)) return false;
        return Objects.equals(stats, that.stats);
    }

    @Override
    public int hashCode() { return Objects.hash(stats); }

    @Override
    public String toString() { return "MachineStatsChangedEvent" + toWire(); }

    public static final class Builder {
        private MachineStats stats;
        private boolean statsSet;

        public Builder stats(MachineStats value) {
            this.stats = value;
            this.statsSet = true;
            return this;
        }
        public MachineStatsChangedEvent build() { return new MachineStatsChangedEvent(this); }
    }
}

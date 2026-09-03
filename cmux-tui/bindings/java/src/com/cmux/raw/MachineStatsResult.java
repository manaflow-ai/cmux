// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineStatsResult implements WireValue {
    private final MachineStats stats;

    private MachineStatsResult(Builder builder) {
        if (!builder.statsSet) throw new IllegalArgumentException("stats is required");
        this.stats = builder.stats;
    }

    public static Builder builder() { return new Builder(); }

    public MachineStats stats() { return stats; }

    public static MachineStatsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineStatsResult");
        Builder builder = builder();
        Object rawStats = Wire.required(object, "stats");
        builder.stats(rawStats == null ? null : MachineStats.fromWire(rawStats));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "stats", stats);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineStatsResult that)) return false;
        return Objects.equals(stats, that.stats);
    }

    @Override
    public int hashCode() { return Objects.hash(stats); }

    @Override
    public String toString() { return "MachineStatsResult" + toWire(); }

    public static final class Builder {
        private MachineStats stats;
        private boolean statsSet;

        public Builder stats(MachineStats value) {
            this.stats = value;
            this.statsSet = true;
            return this;
        }
        public MachineStatsResult build() { return new MachineStatsResult(this); }
    }
}

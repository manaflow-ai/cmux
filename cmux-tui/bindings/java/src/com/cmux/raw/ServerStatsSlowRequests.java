// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsSlowRequests implements WireValue {
    private final UInt64 expectedWaits;
    private final List<ServerStatsSlowRequest> recent;
    private final UInt64 spawnFailures;
    private final UInt64 thresholdMs;
    private final UInt64 total;
    private final UInt64 unwatched;
    private final UInt64 watchdogWakeups;

    private ServerStatsSlowRequests(Builder builder) {
        if (!builder.expectedWaitsSet) throw new IllegalArgumentException("expected_waits is required");
        this.expectedWaits = Wire.nonNull(builder.expectedWaits, "expected_waits");
        if (!builder.recentSet) throw new IllegalArgumentException("recent is required");
        this.recent = List.copyOf(Wire.nonNull(builder.recent, "recent"));
        if (!builder.spawnFailuresSet) throw new IllegalArgumentException("spawn_failures is required");
        this.spawnFailures = Wire.nonNull(builder.spawnFailures, "spawn_failures");
        if (!builder.thresholdMsSet) throw new IllegalArgumentException("threshold_ms is required");
        this.thresholdMs = Wire.nonNull(builder.thresholdMs, "threshold_ms");
        if (!builder.totalSet) throw new IllegalArgumentException("total is required");
        this.total = Wire.nonNull(builder.total, "total");
        if (!builder.unwatchedSet) throw new IllegalArgumentException("unwatched is required");
        this.unwatched = Wire.nonNull(builder.unwatched, "unwatched");
        if (!builder.watchdogWakeupsSet) throw new IllegalArgumentException("watchdog_wakeups is required");
        this.watchdogWakeups = Wire.nonNull(builder.watchdogWakeups, "watchdog_wakeups");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 expectedWaits() { return expectedWaits; }
    public List<ServerStatsSlowRequest> recent() { return recent; }
    public UInt64 spawnFailures() { return spawnFailures; }
    public UInt64 thresholdMs() { return thresholdMs; }
    public UInt64 total() { return total; }
    public UInt64 unwatched() { return unwatched; }
    public UInt64 watchdogWakeups() { return watchdogWakeups; }

    public static ServerStatsSlowRequests fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsSlowRequests");
        Builder builder = builder();
        Object rawExpectedWaits = Wire.required(object, "expected_waits");
        builder.expectedWaits(Wire.uint64(rawExpectedWaits, "ServerStatsSlowRequests.expected_waits"));
        Object rawRecent = Wire.required(object, "recent");
        builder.recent(Wire.array(rawRecent, "ServerStatsSlowRequests.recent", item -> ServerStatsSlowRequest.fromWire(item)));
        Object rawSpawnFailures = Wire.required(object, "spawn_failures");
        builder.spawnFailures(Wire.uint64(rawSpawnFailures, "ServerStatsSlowRequests.spawn_failures"));
        Object rawThresholdMs = Wire.required(object, "threshold_ms");
        builder.thresholdMs(Wire.uint64(rawThresholdMs, "ServerStatsSlowRequests.threshold_ms"));
        Object rawTotal = Wire.required(object, "total");
        builder.total(Wire.uint64(rawTotal, "ServerStatsSlowRequests.total"));
        Object rawUnwatched = Wire.required(object, "unwatched");
        builder.unwatched(Wire.uint64(rawUnwatched, "ServerStatsSlowRequests.unwatched"));
        Object rawWatchdogWakeups = Wire.required(object, "watchdog_wakeups");
        builder.watchdogWakeups(Wire.uint64(rawWatchdogWakeups, "ServerStatsSlowRequests.watchdog_wakeups"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_waits", expectedWaits);
        Wire.put(object, "recent", recent);
        Wire.put(object, "spawn_failures", spawnFailures);
        Wire.put(object, "threshold_ms", thresholdMs);
        Wire.put(object, "total", total);
        Wire.put(object, "unwatched", unwatched);
        Wire.put(object, "watchdog_wakeups", watchdogWakeups);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsSlowRequests that)) return false;
        return Objects.equals(expectedWaits, that.expectedWaits) && Objects.equals(recent, that.recent) && Objects.equals(spawnFailures, that.spawnFailures) && Objects.equals(thresholdMs, that.thresholdMs) && Objects.equals(total, that.total) && Objects.equals(unwatched, that.unwatched) && Objects.equals(watchdogWakeups, that.watchdogWakeups);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedWaits, recent, spawnFailures, thresholdMs, total, unwatched, watchdogWakeups); }

    @Override
    public String toString() { return "ServerStatsSlowRequests" + toWire(); }

    public static final class Builder {
        private UInt64 expectedWaits;
        private boolean expectedWaitsSet;
        private List<ServerStatsSlowRequest> recent;
        private boolean recentSet;
        private UInt64 spawnFailures;
        private boolean spawnFailuresSet;
        private UInt64 thresholdMs;
        private boolean thresholdMsSet;
        private UInt64 total;
        private boolean totalSet;
        private UInt64 unwatched;
        private boolean unwatchedSet;
        private UInt64 watchdogWakeups;
        private boolean watchdogWakeupsSet;

        public Builder expectedWaits(UInt64 value) {
            this.expectedWaits = value;
            this.expectedWaitsSet = true;
            return this;
        }
        public Builder recent(List<ServerStatsSlowRequest> value) {
            this.recent = value;
            this.recentSet = true;
            return this;
        }
        public Builder spawnFailures(UInt64 value) {
            this.spawnFailures = value;
            this.spawnFailuresSet = true;
            return this;
        }
        public Builder thresholdMs(UInt64 value) {
            this.thresholdMs = value;
            this.thresholdMsSet = true;
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = value;
            this.totalSet = true;
            return this;
        }
        public Builder unwatched(UInt64 value) {
            this.unwatched = value;
            this.unwatchedSet = true;
            return this;
        }
        public Builder watchdogWakeups(UInt64 value) {
            this.watchdogWakeups = value;
            this.watchdogWakeupsSet = true;
            return this;
        }
        public ServerStatsSlowRequests build() { return new ServerStatsSlowRequests(this); }
    }
}

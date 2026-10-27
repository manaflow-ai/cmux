// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRuntime implements WireValue {
    private final UInt64 busyMs;
    private final UInt64 busyPeriods;
    private final UInt64 hangs;

    private ServerStatsRuntime(Builder builder) {
        if (!builder.busyMsSet) throw new IllegalArgumentException("busy_ms is required");
        this.busyMs = Wire.nonNull(builder.busyMs, "busy_ms");
        if (!builder.busyPeriodsSet) throw new IllegalArgumentException("busy_periods is required");
        this.busyPeriods = Wire.nonNull(builder.busyPeriods, "busy_periods");
        if (!builder.hangsSet) throw new IllegalArgumentException("hangs is required");
        this.hangs = Wire.nonNull(builder.hangs, "hangs");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 busyMs() { return busyMs; }
    public UInt64 busyPeriods() { return busyPeriods; }
    public UInt64 hangs() { return hangs; }

    public static ServerStatsRuntime fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRuntime");
        Builder builder = builder();
        Object rawBusyMs = Wire.required(object, "busy_ms");
        builder.busyMs(Wire.uint64(rawBusyMs, "ServerStatsRuntime.busy_ms"));
        Object rawBusyPeriods = Wire.required(object, "busy_periods");
        builder.busyPeriods(Wire.uint64(rawBusyPeriods, "ServerStatsRuntime.busy_periods"));
        Object rawHangs = Wire.required(object, "hangs");
        builder.hangs(Wire.uint64(rawHangs, "ServerStatsRuntime.hangs"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "busy_ms", busyMs);
        Wire.put(object, "busy_periods", busyPeriods);
        Wire.put(object, "hangs", hangs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRuntime that)) return false;
        return Objects.equals(busyMs, that.busyMs) && Objects.equals(busyPeriods, that.busyPeriods) && Objects.equals(hangs, that.hangs);
    }

    @Override
    public int hashCode() { return Objects.hash(busyMs, busyPeriods, hangs); }

    @Override
    public String toString() { return "ServerStatsRuntime" + toWire(); }

    public static final class Builder {
        private UInt64 busyMs;
        private boolean busyMsSet;
        private UInt64 busyPeriods;
        private boolean busyPeriodsSet;
        private UInt64 hangs;
        private boolean hangsSet;

        public Builder busyMs(UInt64 value) {
            this.busyMs = value;
            this.busyMsSet = true;
            return this;
        }
        public Builder busyPeriods(UInt64 value) {
            this.busyPeriods = value;
            this.busyPeriodsSet = true;
            return this;
        }
        public Builder hangs(UInt64 value) {
            this.hangs = value;
            this.hangsSet = true;
            return this;
        }
        public ServerStatsRuntime build() { return new ServerStatsRuntime(this); }
    }
}

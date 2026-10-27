// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsPercentiles implements WireValue {
    private final UInt64 count;
    private final UInt64 max;
    private final UInt64 p50;
    private final UInt64 p95;
    private final UInt64 p99;

    private ServerStatsPercentiles(Builder builder) {
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = Wire.nonNull(builder.count, "count");
        if (!builder.maxSet) throw new IllegalArgumentException("max is required");
        this.max = Wire.nonNull(builder.max, "max");
        if (!builder.p50Set) throw new IllegalArgumentException("p50 is required");
        this.p50 = Wire.nonNull(builder.p50, "p50");
        if (!builder.p95Set) throw new IllegalArgumentException("p95 is required");
        this.p95 = Wire.nonNull(builder.p95, "p95");
        if (!builder.p99Set) throw new IllegalArgumentException("p99 is required");
        this.p99 = Wire.nonNull(builder.p99, "p99");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 count() { return count; }
    public UInt64 max() { return max; }
    public UInt64 p50() { return p50; }
    public UInt64 p95() { return p95; }
    public UInt64 p99() { return p99; }

    public static ServerStatsPercentiles fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsPercentiles");
        Builder builder = builder();
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint64(rawCount, "ServerStatsPercentiles.count"));
        Object rawMax = Wire.required(object, "max");
        builder.max(Wire.uint64(rawMax, "ServerStatsPercentiles.max"));
        Object rawP50 = Wire.required(object, "p50");
        builder.p50(Wire.uint64(rawP50, "ServerStatsPercentiles.p50"));
        Object rawP95 = Wire.required(object, "p95");
        builder.p95(Wire.uint64(rawP95, "ServerStatsPercentiles.p95"));
        Object rawP99 = Wire.required(object, "p99");
        builder.p99(Wire.uint64(rawP99, "ServerStatsPercentiles.p99"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "count", count);
        Wire.put(object, "max", max);
        Wire.put(object, "p50", p50);
        Wire.put(object, "p95", p95);
        Wire.put(object, "p99", p99);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsPercentiles that)) return false;
        return Objects.equals(count, that.count) && Objects.equals(max, that.max) && Objects.equals(p50, that.p50) && Objects.equals(p95, that.p95) && Objects.equals(p99, that.p99);
    }

    @Override
    public int hashCode() { return Objects.hash(count, max, p50, p95, p99); }

    @Override
    public String toString() { return "ServerStatsPercentiles" + toWire(); }

    public static final class Builder {
        private UInt64 count;
        private boolean countSet;
        private UInt64 max;
        private boolean maxSet;
        private UInt64 p50;
        private boolean p50Set;
        private UInt64 p95;
        private boolean p95Set;
        private UInt64 p99;
        private boolean p99Set;

        public Builder count(UInt64 value) {
            this.count = value;
            this.countSet = true;
            return this;
        }
        public Builder max(UInt64 value) {
            this.max = value;
            this.maxSet = true;
            return this;
        }
        public Builder p50(UInt64 value) {
            this.p50 = value;
            this.p50Set = true;
            return this;
        }
        public Builder p95(UInt64 value) {
            this.p95 = value;
            this.p95Set = true;
            return this;
        }
        public Builder p99(UInt64 value) {
            this.p99 = value;
            this.p99Set = true;
            return this;
        }
        public ServerStatsPercentiles build() { return new ServerStatsPercentiles(this); }
    }
}

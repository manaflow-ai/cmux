// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsHistogram implements WireValue {
    private final UInt64 count;
    private final UInt64 max;
    private final UInt64 mean;
    private final UInt64 p50;
    private final UInt64 p90;
    private final UInt64 p99;

    private ServerStatsHistogram(Builder builder) {
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = Wire.nonNull(builder.count, "count");
        if (!builder.maxSet) throw new IllegalArgumentException("max is required");
        this.max = Wire.nonNull(builder.max, "max");
        if (!builder.meanSet) throw new IllegalArgumentException("mean is required");
        this.mean = Wire.nonNull(builder.mean, "mean");
        if (!builder.p50Set) throw new IllegalArgumentException("p50 is required");
        this.p50 = Wire.nonNull(builder.p50, "p50");
        if (!builder.p90Set) throw new IllegalArgumentException("p90 is required");
        this.p90 = Wire.nonNull(builder.p90, "p90");
        if (!builder.p99Set) throw new IllegalArgumentException("p99 is required");
        this.p99 = Wire.nonNull(builder.p99, "p99");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 count() { return count; }
    public UInt64 max() { return max; }
    public UInt64 mean() { return mean; }
    public UInt64 p50() { return p50; }
    public UInt64 p90() { return p90; }
    public UInt64 p99() { return p99; }

    public static ServerStatsHistogram fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsHistogram");
        Builder builder = builder();
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint64(rawCount, "ServerStatsHistogram.count"));
        Object rawMax = Wire.required(object, "max");
        builder.max(Wire.uint64(rawMax, "ServerStatsHistogram.max"));
        Object rawMean = Wire.required(object, "mean");
        builder.mean(Wire.uint64(rawMean, "ServerStatsHistogram.mean"));
        Object rawP50 = Wire.required(object, "p50");
        builder.p50(Wire.uint64(rawP50, "ServerStatsHistogram.p50"));
        Object rawP90 = Wire.required(object, "p90");
        builder.p90(Wire.uint64(rawP90, "ServerStatsHistogram.p90"));
        Object rawP99 = Wire.required(object, "p99");
        builder.p99(Wire.uint64(rawP99, "ServerStatsHistogram.p99"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "count", count);
        Wire.put(object, "max", max);
        Wire.put(object, "mean", mean);
        Wire.put(object, "p50", p50);
        Wire.put(object, "p90", p90);
        Wire.put(object, "p99", p99);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsHistogram that)) return false;
        return Objects.equals(count, that.count) && Objects.equals(max, that.max) && Objects.equals(mean, that.mean) && Objects.equals(p50, that.p50) && Objects.equals(p90, that.p90) && Objects.equals(p99, that.p99);
    }

    @Override
    public int hashCode() { return Objects.hash(count, max, mean, p50, p90, p99); }

    @Override
    public String toString() { return "ServerStatsHistogram" + toWire(); }

    public static final class Builder {
        private UInt64 count;
        private boolean countSet;
        private UInt64 max;
        private boolean maxSet;
        private UInt64 mean;
        private boolean meanSet;
        private UInt64 p50;
        private boolean p50Set;
        private UInt64 p90;
        private boolean p90Set;
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
        public Builder mean(UInt64 value) {
            this.mean = value;
            this.meanSet = true;
            return this;
        }
        public Builder p50(UInt64 value) {
            this.p50 = value;
            this.p50Set = true;
            return this;
        }
        public Builder p90(UInt64 value) {
            this.p90 = value;
            this.p90Set = true;
            return this;
        }
        public Builder p99(UInt64 value) {
            this.p99 = value;
            this.p99Set = true;
            return this;
        }
        public ServerStatsHistogram build() { return new ServerStatsHistogram(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpcRing implements WireValue {
    private final UInt64 laps;
    private final UInt64 resyncs;

    private ServerStatsIpcRing(Builder builder) {
        if (!builder.lapsSet) throw new IllegalArgumentException("laps is required");
        this.laps = Wire.nonNull(builder.laps, "laps");
        if (!builder.resyncsSet) throw new IllegalArgumentException("resyncs is required");
        this.resyncs = Wire.nonNull(builder.resyncs, "resyncs");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 laps() { return laps; }
    public UInt64 resyncs() { return resyncs; }

    public static ServerStatsIpcRing fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpcRing");
        Builder builder = builder();
        Object rawLaps = Wire.required(object, "laps");
        builder.laps(Wire.uint64(rawLaps, "ServerStatsIpcRing.laps"));
        Object rawResyncs = Wire.required(object, "resyncs");
        builder.resyncs(Wire.uint64(rawResyncs, "ServerStatsIpcRing.resyncs"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "laps", laps);
        Wire.put(object, "resyncs", resyncs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpcRing that)) return false;
        return Objects.equals(laps, that.laps) && Objects.equals(resyncs, that.resyncs);
    }

    @Override
    public int hashCode() { return Objects.hash(laps, resyncs); }

    @Override
    public String toString() { return "ServerStatsIpcRing" + toWire(); }

    public static final class Builder {
        private UInt64 laps;
        private boolean lapsSet;
        private UInt64 resyncs;
        private boolean resyncsSet;

        public Builder laps(UInt64 value) {
            this.laps = value;
            this.lapsSet = true;
            return this;
        }
        public Builder resyncs(UInt64 value) {
            this.resyncs = value;
            this.resyncsSet = true;
            return this;
        }
        public ServerStatsIpcRing build() { return new ServerStatsIpcRing(this); }
    }
}

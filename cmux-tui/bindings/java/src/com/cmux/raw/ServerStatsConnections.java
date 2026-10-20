// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsConnections implements WireValue {
    private final UInt64 accepted;
    private final UInt64 active;
    private final UInt64 limit;
    private final UInt64 peak;
    private final UInt64 refused;

    private ServerStatsConnections(Builder builder) {
        if (!builder.acceptedSet) throw new IllegalArgumentException("accepted is required");
        this.accepted = Wire.nonNull(builder.accepted, "accepted");
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = Wire.nonNull(builder.active, "active");
        if (!builder.limitSet) throw new IllegalArgumentException("limit is required");
        this.limit = Wire.nonNull(builder.limit, "limit");
        if (!builder.peakSet) throw new IllegalArgumentException("peak is required");
        this.peak = Wire.nonNull(builder.peak, "peak");
        if (!builder.refusedSet) throw new IllegalArgumentException("refused is required");
        this.refused = Wire.nonNull(builder.refused, "refused");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 accepted() { return accepted; }
    public UInt64 active() { return active; }
    public UInt64 limit() { return limit; }
    public UInt64 peak() { return peak; }
    public UInt64 refused() { return refused; }

    public static ServerStatsConnections fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsConnections");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        builder.accepted(Wire.uint64(rawAccepted, "ServerStatsConnections.accepted"));
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.uint64(rawActive, "ServerStatsConnections.active"));
        Object rawLimit = Wire.required(object, "limit");
        builder.limit(Wire.uint64(rawLimit, "ServerStatsConnections.limit"));
        Object rawPeak = Wire.required(object, "peak");
        builder.peak(Wire.uint64(rawPeak, "ServerStatsConnections.peak"));
        Object rawRefused = Wire.required(object, "refused");
        builder.refused(Wire.uint64(rawRefused, "ServerStatsConnections.refused"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", accepted);
        Wire.put(object, "active", active);
        Wire.put(object, "limit", limit);
        Wire.put(object, "peak", peak);
        Wire.put(object, "refused", refused);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsConnections that)) return false;
        return Objects.equals(accepted, that.accepted) && Objects.equals(active, that.active) && Objects.equals(limit, that.limit) && Objects.equals(peak, that.peak) && Objects.equals(refused, that.refused);
    }

    @Override
    public int hashCode() { return Objects.hash(accepted, active, limit, peak, refused); }

    @Override
    public String toString() { return "ServerStatsConnections" + toWire(); }

    public static final class Builder {
        private UInt64 accepted;
        private boolean acceptedSet;
        private UInt64 active;
        private boolean activeSet;
        private UInt64 limit;
        private boolean limitSet;
        private UInt64 peak;
        private boolean peakSet;
        private UInt64 refused;
        private boolean refusedSet;

        public Builder accepted(UInt64 value) {
            this.accepted = value;
            this.acceptedSet = true;
            return this;
        }
        public Builder active(UInt64 value) {
            this.active = value;
            this.activeSet = true;
            return this;
        }
        public Builder limit(UInt64 value) {
            this.limit = value;
            this.limitSet = true;
            return this;
        }
        public Builder peak(UInt64 value) {
            this.peak = value;
            this.peakSet = true;
            return this;
        }
        public Builder refused(UInt64 value) {
            this.refused = value;
            this.refusedSet = true;
            return this;
        }
        public ServerStatsConnections build() { return new ServerStatsConnections(this); }
    }
}

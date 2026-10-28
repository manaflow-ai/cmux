// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockClass implements WireValue {
    private final ServerStatsHistogram holdUs;
    private final UInt64 waitP95Us;
    private final ServerStatsHistogram waitUs;

    private ServerStatsLockClass(Builder builder) {
        if (!builder.holdUsSet) throw new IllegalArgumentException("hold_us is required");
        this.holdUs = Wire.nonNull(builder.holdUs, "hold_us");
        if (!builder.waitP95UsSet) throw new IllegalArgumentException("wait_p95_us is required");
        this.waitP95Us = Wire.nonNull(builder.waitP95Us, "wait_p95_us");
        if (!builder.waitUsSet) throw new IllegalArgumentException("wait_us is required");
        this.waitUs = Wire.nonNull(builder.waitUs, "wait_us");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsHistogram holdUs() { return holdUs; }
    public UInt64 waitP95Us() { return waitP95Us; }
    public ServerStatsHistogram waitUs() { return waitUs; }

    public static ServerStatsLockClass fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockClass");
        Builder builder = builder();
        Object rawHoldUs = Wire.required(object, "hold_us");
        builder.holdUs(ServerStatsHistogram.fromWire(rawHoldUs));
        Object rawWaitP95Us = Wire.required(object, "wait_p95_us");
        builder.waitP95Us(Wire.uint64(rawWaitP95Us, "ServerStatsLockClass.wait_p95_us"));
        Object rawWaitUs = Wire.required(object, "wait_us");
        builder.waitUs(ServerStatsHistogram.fromWire(rawWaitUs));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "hold_us", holdUs);
        Wire.put(object, "wait_p95_us", waitP95Us);
        Wire.put(object, "wait_us", waitUs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockClass that)) return false;
        return Objects.equals(holdUs, that.holdUs) && Objects.equals(waitP95Us, that.waitP95Us) && Objects.equals(waitUs, that.waitUs);
    }

    @Override
    public int hashCode() { return Objects.hash(holdUs, waitP95Us, waitUs); }

    @Override
    public String toString() { return "ServerStatsLockClass" + toWire(); }

    public static final class Builder {
        private ServerStatsHistogram holdUs;
        private boolean holdUsSet;
        private UInt64 waitP95Us;
        private boolean waitP95UsSet;
        private ServerStatsHistogram waitUs;
        private boolean waitUsSet;

        public Builder holdUs(ServerStatsHistogram value) {
            this.holdUs = value;
            this.holdUsSet = true;
            return this;
        }
        public Builder waitP95Us(UInt64 value) {
            this.waitP95Us = value;
            this.waitP95UsSet = true;
            return this;
        }
        public Builder waitUs(ServerStatsHistogram value) {
            this.waitUs = value;
            this.waitUsSet = true;
            return this;
        }
        public ServerStatsLockClass build() { return new ServerStatsLockClass(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockStall implements WireValue {
    private final String blocker;
    private final UInt64 waitedUs;
    private final String waiter;

    private ServerStatsLockStall(Builder builder) {
        if (!builder.blockerSet) throw new IllegalArgumentException("blocker is required");
        this.blocker = builder.blocker;
        if (!builder.waitedUsSet) throw new IllegalArgumentException("waited_us is required");
        this.waitedUs = Wire.nonNull(builder.waitedUs, "waited_us");
        if (!builder.waiterSet) throw new IllegalArgumentException("waiter is required");
        this.waiter = Wire.nonNull(builder.waiter, "waiter");
    }

    public static Builder builder() { return new Builder(); }

    public String blocker() { return blocker; }
    public UInt64 waitedUs() { return waitedUs; }
    public String waiter() { return waiter; }

    public static ServerStatsLockStall fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockStall");
        Builder builder = builder();
        Object rawBlocker = Wire.required(object, "blocker");
        builder.blocker(rawBlocker == null ? null : Wire.string(rawBlocker, "ServerStatsLockStall.blocker"));
        Object rawWaitedUs = Wire.required(object, "waited_us");
        builder.waitedUs(Wire.uint64(rawWaitedUs, "ServerStatsLockStall.waited_us"));
        Object rawWaiter = Wire.required(object, "waiter");
        builder.waiter(Wire.string(rawWaiter, "ServerStatsLockStall.waiter"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "blocker", blocker);
        Wire.put(object, "waited_us", waitedUs);
        Wire.put(object, "waiter", waiter);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockStall that)) return false;
        return Objects.equals(blocker, that.blocker) && Objects.equals(waitedUs, that.waitedUs) && Objects.equals(waiter, that.waiter);
    }

    @Override
    public int hashCode() { return Objects.hash(blocker, waitedUs, waiter); }

    @Override
    public String toString() { return "ServerStatsLockStall" + toWire(); }

    public static final class Builder {
        private String blocker;
        private boolean blockerSet;
        private UInt64 waitedUs;
        private boolean waitedUsSet;
        private String waiter;
        private boolean waiterSet;

        public Builder blocker(String value) {
            this.blocker = value;
            this.blockerSet = true;
            return this;
        }
        public Builder waitedUs(UInt64 value) {
            this.waitedUs = value;
            this.waitedUsSet = true;
            return this;
        }
        public Builder waiter(String value) {
            this.waiter = value;
            this.waiterSet = true;
            return this;
        }
        public ServerStatsLockStall build() { return new ServerStatsLockStall(this); }
    }
}

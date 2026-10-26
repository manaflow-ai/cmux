// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockWait implements WireValue {
    private final Field<String> holder;
    private final String lock;
    private final String site;
    private final UInt64 waitedUs;
    private final String waiter;

    private ServerStatsLockWait(Builder builder) {
        this.holder = builder.holder;
        if (!builder.lockSet) throw new IllegalArgumentException("lock is required");
        this.lock = Wire.nonNull(builder.lock, "lock");
        if (!builder.siteSet) throw new IllegalArgumentException("site is required");
        this.site = Wire.nonNull(builder.site, "site");
        if (!builder.waitedUsSet) throw new IllegalArgumentException("waited_us is required");
        this.waitedUs = Wire.nonNull(builder.waitedUs, "waited_us");
        if (!builder.waiterSet) throw new IllegalArgumentException("waiter is required");
        this.waiter = Wire.nonNull(builder.waiter, "waiter");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> holder() { return holder; }
    public String lock() { return lock; }
    public String site() { return site; }
    public UInt64 waitedUs() { return waitedUs; }
    public String waiter() { return waiter; }

    public static ServerStatsLockWait fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockWait");
        Builder builder = builder();
        Object rawHolder = Wire.optional(object, "holder");
        if (!Wire.isMissing(rawHolder)) {
            builder.holder(Wire.string(rawHolder, "ServerStatsLockWait.holder"));
        }
        Object rawLock = Wire.required(object, "lock");
        builder.lock(Wire.string(rawLock, "ServerStatsLockWait.lock"));
        Object rawSite = Wire.required(object, "site");
        builder.site(Wire.string(rawSite, "ServerStatsLockWait.site"));
        Object rawWaitedUs = Wire.required(object, "waited_us");
        builder.waitedUs(Wire.uint64(rawWaitedUs, "ServerStatsLockWait.waited_us"));
        Object rawWaiter = Wire.required(object, "waiter");
        builder.waiter(Wire.string(rawWaiter, "ServerStatsLockWait.waiter"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "holder", holder);
        Wire.put(object, "lock", lock);
        Wire.put(object, "site", site);
        Wire.put(object, "waited_us", waitedUs);
        Wire.put(object, "waiter", waiter);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockWait that)) return false;
        return Objects.equals(holder, that.holder) && Objects.equals(lock, that.lock) && Objects.equals(site, that.site) && Objects.equals(waitedUs, that.waitedUs) && Objects.equals(waiter, that.waiter);
    }

    @Override
    public int hashCode() { return Objects.hash(holder, lock, site, waitedUs, waiter); }

    @Override
    public String toString() { return "ServerStatsLockWait" + toWire(); }

    public static final class Builder {
        private Field<String> holder = Field.omitted();
        private String lock;
        private boolean lockSet;
        private String site;
        private boolean siteSet;
        private UInt64 waitedUs;
        private boolean waitedUsSet;
        private String waiter;
        private boolean waiterSet;

        public Builder holder(String value) {
            this.holder = Field.of(value);
            return this;
        }
        public Builder lock(String value) {
            this.lock = value;
            this.lockSet = true;
            return this;
        }
        public Builder site(String value) {
            this.site = value;
            this.siteSet = true;
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
        public ServerStatsLockWait build() { return new ServerStatsLockWait(this); }
    }
}

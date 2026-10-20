// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRegistryLock implements WireValue {
    private final UInt64 contendedAcquisitions;
    private final ServerStatsHistogram holdUs;
    private final ServerStatsLockHolder holder;
    private final ServerStatsLockStall lastStall;
    private final UInt64 stalls;
    private final List<ServerStatsLockSite> topSites;
    private final ServerStatsHistogram waitUs;

    private ServerStatsRegistryLock(Builder builder) {
        if (!builder.contendedAcquisitionsSet) throw new IllegalArgumentException("contended_acquisitions is required");
        this.contendedAcquisitions = Wire.nonNull(builder.contendedAcquisitions, "contended_acquisitions");
        if (!builder.holdUsSet) throw new IllegalArgumentException("hold_us is required");
        this.holdUs = Wire.nonNull(builder.holdUs, "hold_us");
        if (!builder.holderSet) throw new IllegalArgumentException("holder is required");
        this.holder = builder.holder;
        if (!builder.lastStallSet) throw new IllegalArgumentException("last_stall is required");
        this.lastStall = builder.lastStall;
        if (!builder.stallsSet) throw new IllegalArgumentException("stalls is required");
        this.stalls = Wire.nonNull(builder.stalls, "stalls");
        if (!builder.topSitesSet) throw new IllegalArgumentException("top_sites is required");
        this.topSites = List.copyOf(Wire.nonNull(builder.topSites, "top_sites"));
        if (!builder.waitUsSet) throw new IllegalArgumentException("wait_us is required");
        this.waitUs = Wire.nonNull(builder.waitUs, "wait_us");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 contendedAcquisitions() { return contendedAcquisitions; }
    public ServerStatsHistogram holdUs() { return holdUs; }
    public ServerStatsLockHolder holder() { return holder; }
    public ServerStatsLockStall lastStall() { return lastStall; }
    public UInt64 stalls() { return stalls; }
    public List<ServerStatsLockSite> topSites() { return topSites; }
    public ServerStatsHistogram waitUs() { return waitUs; }

    public static ServerStatsRegistryLock fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRegistryLock");
        Builder builder = builder();
        Object rawContendedAcquisitions = Wire.required(object, "contended_acquisitions");
        builder.contendedAcquisitions(Wire.uint64(rawContendedAcquisitions, "ServerStatsRegistryLock.contended_acquisitions"));
        Object rawHoldUs = Wire.required(object, "hold_us");
        builder.holdUs(ServerStatsHistogram.fromWire(rawHoldUs));
        Object rawHolder = Wire.required(object, "holder");
        builder.holder(rawHolder == null ? null : ServerStatsLockHolder.fromWire(rawHolder));
        Object rawLastStall = Wire.required(object, "last_stall");
        builder.lastStall(rawLastStall == null ? null : ServerStatsLockStall.fromWire(rawLastStall));
        Object rawStalls = Wire.required(object, "stalls");
        builder.stalls(Wire.uint64(rawStalls, "ServerStatsRegistryLock.stalls"));
        Object rawTopSites = Wire.required(object, "top_sites");
        builder.topSites(Wire.array(rawTopSites, "ServerStatsRegistryLock.top_sites", item -> ServerStatsLockSite.fromWire(item)));
        Object rawWaitUs = Wire.required(object, "wait_us");
        builder.waitUs(ServerStatsHistogram.fromWire(rawWaitUs));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "contended_acquisitions", contendedAcquisitions);
        Wire.put(object, "hold_us", holdUs);
        Wire.put(object, "holder", holder);
        Wire.put(object, "last_stall", lastStall);
        Wire.put(object, "stalls", stalls);
        Wire.put(object, "top_sites", topSites);
        Wire.put(object, "wait_us", waitUs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRegistryLock that)) return false;
        return Objects.equals(contendedAcquisitions, that.contendedAcquisitions) && Objects.equals(holdUs, that.holdUs) && Objects.equals(holder, that.holder) && Objects.equals(lastStall, that.lastStall) && Objects.equals(stalls, that.stalls) && Objects.equals(topSites, that.topSites) && Objects.equals(waitUs, that.waitUs);
    }

    @Override
    public int hashCode() { return Objects.hash(contendedAcquisitions, holdUs, holder, lastStall, stalls, topSites, waitUs); }

    @Override
    public String toString() { return "ServerStatsRegistryLock" + toWire(); }

    public static final class Builder {
        private UInt64 contendedAcquisitions;
        private boolean contendedAcquisitionsSet;
        private ServerStatsHistogram holdUs;
        private boolean holdUsSet;
        private ServerStatsLockHolder holder;
        private boolean holderSet;
        private ServerStatsLockStall lastStall;
        private boolean lastStallSet;
        private UInt64 stalls;
        private boolean stallsSet;
        private List<ServerStatsLockSite> topSites;
        private boolean topSitesSet;
        private ServerStatsHistogram waitUs;
        private boolean waitUsSet;

        public Builder contendedAcquisitions(UInt64 value) {
            this.contendedAcquisitions = value;
            this.contendedAcquisitionsSet = true;
            return this;
        }
        public Builder holdUs(ServerStatsHistogram value) {
            this.holdUs = value;
            this.holdUsSet = true;
            return this;
        }
        public Builder holder(ServerStatsLockHolder value) {
            this.holder = value;
            this.holderSet = true;
            return this;
        }
        public Builder lastStall(ServerStatsLockStall value) {
            this.lastStall = value;
            this.lastStallSet = true;
            return this;
        }
        public Builder stalls(UInt64 value) {
            this.stalls = value;
            this.stallsSet = true;
            return this;
        }
        public Builder topSites(List<ServerStatsLockSite> value) {
            this.topSites = value;
            this.topSitesSet = true;
            return this;
        }
        public Builder waitUs(ServerStatsHistogram value) {
            this.waitUs = value;
            this.waitUsSet = true;
            return this;
        }
        public ServerStatsRegistryLock build() { return new ServerStatsRegistryLock(this); }
    }
}

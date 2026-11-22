// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockDetail implements WireValue {
    private final List<ServerStatsLockSiteDetail> byHoldP99;
    private final List<ServerStatsLockSiteDetail> byHoldTotal;
    private final UInt64 contendedAcquisitions;
    private final ServerStatsHistogram holdUs;
    private final ServerStatsLockHolder holder;
    private final ServerStatsLockStall lastStall;
    private final UInt64 sites;
    private final UInt64 stalls;
    private final ServerStatsHistogram waitUs;

    private ServerStatsLockDetail(Builder builder) {
        if (!builder.byHoldP99Set) throw new IllegalArgumentException("by_hold_p99 is required");
        this.byHoldP99 = List.copyOf(Wire.nonNull(builder.byHoldP99, "by_hold_p99"));
        if (!builder.byHoldTotalSet) throw new IllegalArgumentException("by_hold_total is required");
        this.byHoldTotal = List.copyOf(Wire.nonNull(builder.byHoldTotal, "by_hold_total"));
        if (!builder.contendedAcquisitionsSet) throw new IllegalArgumentException("contended_acquisitions is required");
        this.contendedAcquisitions = Wire.nonNull(builder.contendedAcquisitions, "contended_acquisitions");
        if (!builder.holdUsSet) throw new IllegalArgumentException("hold_us is required");
        this.holdUs = Wire.nonNull(builder.holdUs, "hold_us");
        if (!builder.holderSet) throw new IllegalArgumentException("holder is required");
        this.holder = builder.holder;
        if (!builder.lastStallSet) throw new IllegalArgumentException("last_stall is required");
        this.lastStall = builder.lastStall;
        if (!builder.sitesSet) throw new IllegalArgumentException("sites is required");
        this.sites = Wire.nonNull(builder.sites, "sites");
        if (!builder.stallsSet) throw new IllegalArgumentException("stalls is required");
        this.stalls = Wire.nonNull(builder.stalls, "stalls");
        if (!builder.waitUsSet) throw new IllegalArgumentException("wait_us is required");
        this.waitUs = Wire.nonNull(builder.waitUs, "wait_us");
    }

    public static Builder builder() { return new Builder(); }

    public List<ServerStatsLockSiteDetail> byHoldP99() { return byHoldP99; }
    public List<ServerStatsLockSiteDetail> byHoldTotal() { return byHoldTotal; }
    public UInt64 contendedAcquisitions() { return contendedAcquisitions; }
    public ServerStatsHistogram holdUs() { return holdUs; }
    public ServerStatsLockHolder holder() { return holder; }
    public ServerStatsLockStall lastStall() { return lastStall; }
    public UInt64 sites() { return sites; }
    public UInt64 stalls() { return stalls; }
    public ServerStatsHistogram waitUs() { return waitUs; }

    public static ServerStatsLockDetail fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockDetail");
        Builder builder = builder();
        Object rawByHoldP99 = Wire.required(object, "by_hold_p99");
        builder.byHoldP99(Wire.array(rawByHoldP99, "ServerStatsLockDetail.by_hold_p99", item -> ServerStatsLockSiteDetail.fromWire(item)));
        Object rawByHoldTotal = Wire.required(object, "by_hold_total");
        builder.byHoldTotal(Wire.array(rawByHoldTotal, "ServerStatsLockDetail.by_hold_total", item -> ServerStatsLockSiteDetail.fromWire(item)));
        Object rawContendedAcquisitions = Wire.required(object, "contended_acquisitions");
        builder.contendedAcquisitions(Wire.uint64(rawContendedAcquisitions, "ServerStatsLockDetail.contended_acquisitions"));
        Object rawHoldUs = Wire.required(object, "hold_us");
        builder.holdUs(ServerStatsHistogram.fromWire(rawHoldUs));
        Object rawHolder = Wire.required(object, "holder");
        builder.holder(rawHolder == null ? null : ServerStatsLockHolder.fromWire(rawHolder));
        Object rawLastStall = Wire.required(object, "last_stall");
        builder.lastStall(rawLastStall == null ? null : ServerStatsLockStall.fromWire(rawLastStall));
        Object rawSites = Wire.required(object, "sites");
        builder.sites(Wire.uint64(rawSites, "ServerStatsLockDetail.sites"));
        Object rawStalls = Wire.required(object, "stalls");
        builder.stalls(Wire.uint64(rawStalls, "ServerStatsLockDetail.stalls"));
        Object rawWaitUs = Wire.required(object, "wait_us");
        builder.waitUs(ServerStatsHistogram.fromWire(rawWaitUs));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "by_hold_p99", byHoldP99);
        Wire.put(object, "by_hold_total", byHoldTotal);
        Wire.put(object, "contended_acquisitions", contendedAcquisitions);
        Wire.put(object, "hold_us", holdUs);
        Wire.put(object, "holder", holder);
        Wire.put(object, "last_stall", lastStall);
        Wire.put(object, "sites", sites);
        Wire.put(object, "stalls", stalls);
        Wire.put(object, "wait_us", waitUs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockDetail that)) return false;
        return Objects.equals(byHoldP99, that.byHoldP99) && Objects.equals(byHoldTotal, that.byHoldTotal) && Objects.equals(contendedAcquisitions, that.contendedAcquisitions) && Objects.equals(holdUs, that.holdUs) && Objects.equals(holder, that.holder) && Objects.equals(lastStall, that.lastStall) && Objects.equals(sites, that.sites) && Objects.equals(stalls, that.stalls) && Objects.equals(waitUs, that.waitUs);
    }

    @Override
    public int hashCode() { return Objects.hash(byHoldP99, byHoldTotal, contendedAcquisitions, holdUs, holder, lastStall, sites, stalls, waitUs); }

    @Override
    public String toString() { return "ServerStatsLockDetail" + toWire(); }

    public static final class Builder {
        private List<ServerStatsLockSiteDetail> byHoldP99;
        private boolean byHoldP99Set;
        private List<ServerStatsLockSiteDetail> byHoldTotal;
        private boolean byHoldTotalSet;
        private UInt64 contendedAcquisitions;
        private boolean contendedAcquisitionsSet;
        private ServerStatsHistogram holdUs;
        private boolean holdUsSet;
        private ServerStatsLockHolder holder;
        private boolean holderSet;
        private ServerStatsLockStall lastStall;
        private boolean lastStallSet;
        private UInt64 sites;
        private boolean sitesSet;
        private UInt64 stalls;
        private boolean stallsSet;
        private ServerStatsHistogram waitUs;
        private boolean waitUsSet;

        public Builder byHoldP99(List<ServerStatsLockSiteDetail> value) {
            this.byHoldP99 = value;
            this.byHoldP99Set = true;
            return this;
        }
        public Builder byHoldTotal(List<ServerStatsLockSiteDetail> value) {
            this.byHoldTotal = value;
            this.byHoldTotalSet = true;
            return this;
        }
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
        public Builder sites(UInt64 value) {
            this.sites = value;
            this.sitesSet = true;
            return this;
        }
        public Builder stalls(UInt64 value) {
            this.stalls = value;
            this.stallsSet = true;
            return this;
        }
        public Builder waitUs(ServerStatsHistogram value) {
            this.waitUs = value;
            this.waitUsSet = true;
            return this;
        }
        public ServerStatsLockDetail build() { return new ServerStatsLockDetail(this); }
    }
}

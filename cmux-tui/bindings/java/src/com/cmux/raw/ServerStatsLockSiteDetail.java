// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockSiteDetail implements WireValue {
    private final UInt64 acquisitions;
    private final UInt64 holdMaxUs;
    private final UInt64 holdP99Us;
    private final UInt64 holdTotalUs;
    private final String site;
    private final UInt64 waitMaxUs;
    private final UInt64 waitP99Us;
    private final UInt64 waitTotalUs;

    private ServerStatsLockSiteDetail(Builder builder) {
        if (!builder.acquisitionsSet) throw new IllegalArgumentException("acquisitions is required");
        this.acquisitions = Wire.nonNull(builder.acquisitions, "acquisitions");
        if (!builder.holdMaxUsSet) throw new IllegalArgumentException("hold_max_us is required");
        this.holdMaxUs = Wire.nonNull(builder.holdMaxUs, "hold_max_us");
        if (!builder.holdP99UsSet) throw new IllegalArgumentException("hold_p99_us is required");
        this.holdP99Us = Wire.nonNull(builder.holdP99Us, "hold_p99_us");
        if (!builder.holdTotalUsSet) throw new IllegalArgumentException("hold_total_us is required");
        this.holdTotalUs = Wire.nonNull(builder.holdTotalUs, "hold_total_us");
        if (!builder.siteSet) throw new IllegalArgumentException("site is required");
        this.site = Wire.nonNull(builder.site, "site");
        if (!builder.waitMaxUsSet) throw new IllegalArgumentException("wait_max_us is required");
        this.waitMaxUs = Wire.nonNull(builder.waitMaxUs, "wait_max_us");
        if (!builder.waitP99UsSet) throw new IllegalArgumentException("wait_p99_us is required");
        this.waitP99Us = Wire.nonNull(builder.waitP99Us, "wait_p99_us");
        if (!builder.waitTotalUsSet) throw new IllegalArgumentException("wait_total_us is required");
        this.waitTotalUs = Wire.nonNull(builder.waitTotalUs, "wait_total_us");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 acquisitions() { return acquisitions; }
    public UInt64 holdMaxUs() { return holdMaxUs; }
    public UInt64 holdP99Us() { return holdP99Us; }
    public UInt64 holdTotalUs() { return holdTotalUs; }
    public String site() { return site; }
    public UInt64 waitMaxUs() { return waitMaxUs; }
    public UInt64 waitP99Us() { return waitP99Us; }
    public UInt64 waitTotalUs() { return waitTotalUs; }

    public static ServerStatsLockSiteDetail fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockSiteDetail");
        Builder builder = builder();
        Object rawAcquisitions = Wire.required(object, "acquisitions");
        builder.acquisitions(Wire.uint64(rawAcquisitions, "ServerStatsLockSiteDetail.acquisitions"));
        Object rawHoldMaxUs = Wire.required(object, "hold_max_us");
        builder.holdMaxUs(Wire.uint64(rawHoldMaxUs, "ServerStatsLockSiteDetail.hold_max_us"));
        Object rawHoldP99Us = Wire.required(object, "hold_p99_us");
        builder.holdP99Us(Wire.uint64(rawHoldP99Us, "ServerStatsLockSiteDetail.hold_p99_us"));
        Object rawHoldTotalUs = Wire.required(object, "hold_total_us");
        builder.holdTotalUs(Wire.uint64(rawHoldTotalUs, "ServerStatsLockSiteDetail.hold_total_us"));
        Object rawSite = Wire.required(object, "site");
        builder.site(Wire.string(rawSite, "ServerStatsLockSiteDetail.site"));
        Object rawWaitMaxUs = Wire.required(object, "wait_max_us");
        builder.waitMaxUs(Wire.uint64(rawWaitMaxUs, "ServerStatsLockSiteDetail.wait_max_us"));
        Object rawWaitP99Us = Wire.required(object, "wait_p99_us");
        builder.waitP99Us(Wire.uint64(rawWaitP99Us, "ServerStatsLockSiteDetail.wait_p99_us"));
        Object rawWaitTotalUs = Wire.required(object, "wait_total_us");
        builder.waitTotalUs(Wire.uint64(rawWaitTotalUs, "ServerStatsLockSiteDetail.wait_total_us"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "acquisitions", acquisitions);
        Wire.put(object, "hold_max_us", holdMaxUs);
        Wire.put(object, "hold_p99_us", holdP99Us);
        Wire.put(object, "hold_total_us", holdTotalUs);
        Wire.put(object, "site", site);
        Wire.put(object, "wait_max_us", waitMaxUs);
        Wire.put(object, "wait_p99_us", waitP99Us);
        Wire.put(object, "wait_total_us", waitTotalUs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockSiteDetail that)) return false;
        return Objects.equals(acquisitions, that.acquisitions) && Objects.equals(holdMaxUs, that.holdMaxUs) && Objects.equals(holdP99Us, that.holdP99Us) && Objects.equals(holdTotalUs, that.holdTotalUs) && Objects.equals(site, that.site) && Objects.equals(waitMaxUs, that.waitMaxUs) && Objects.equals(waitP99Us, that.waitP99Us) && Objects.equals(waitTotalUs, that.waitTotalUs);
    }

    @Override
    public int hashCode() { return Objects.hash(acquisitions, holdMaxUs, holdP99Us, holdTotalUs, site, waitMaxUs, waitP99Us, waitTotalUs); }

    @Override
    public String toString() { return "ServerStatsLockSiteDetail" + toWire(); }

    public static final class Builder {
        private UInt64 acquisitions;
        private boolean acquisitionsSet;
        private UInt64 holdMaxUs;
        private boolean holdMaxUsSet;
        private UInt64 holdP99Us;
        private boolean holdP99UsSet;
        private UInt64 holdTotalUs;
        private boolean holdTotalUsSet;
        private String site;
        private boolean siteSet;
        private UInt64 waitMaxUs;
        private boolean waitMaxUsSet;
        private UInt64 waitP99Us;
        private boolean waitP99UsSet;
        private UInt64 waitTotalUs;
        private boolean waitTotalUsSet;

        public Builder acquisitions(UInt64 value) {
            this.acquisitions = value;
            this.acquisitionsSet = true;
            return this;
        }
        public Builder holdMaxUs(UInt64 value) {
            this.holdMaxUs = value;
            this.holdMaxUsSet = true;
            return this;
        }
        public Builder holdP99Us(UInt64 value) {
            this.holdP99Us = value;
            this.holdP99UsSet = true;
            return this;
        }
        public Builder holdTotalUs(UInt64 value) {
            this.holdTotalUs = value;
            this.holdTotalUsSet = true;
            return this;
        }
        public Builder site(String value) {
            this.site = value;
            this.siteSet = true;
            return this;
        }
        public Builder waitMaxUs(UInt64 value) {
            this.waitMaxUs = value;
            this.waitMaxUsSet = true;
            return this;
        }
        public Builder waitP99Us(UInt64 value) {
            this.waitP99Us = value;
            this.waitP99UsSet = true;
            return this;
        }
        public Builder waitTotalUs(UInt64 value) {
            this.waitTotalUs = value;
            this.waitTotalUsSet = true;
            return this;
        }
        public ServerStatsLockSiteDetail build() { return new ServerStatsLockSiteDetail(this); }
    }
}

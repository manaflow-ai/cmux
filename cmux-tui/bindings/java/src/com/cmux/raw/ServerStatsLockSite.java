// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockSite implements WireValue {
    private final UInt64 acquisitions;
    private final UInt64 holdMaxUs;
    private final UInt64 holdTotalUs;
    private final String site;

    private ServerStatsLockSite(Builder builder) {
        if (!builder.acquisitionsSet) throw new IllegalArgumentException("acquisitions is required");
        this.acquisitions = Wire.nonNull(builder.acquisitions, "acquisitions");
        if (!builder.holdMaxUsSet) throw new IllegalArgumentException("hold_max_us is required");
        this.holdMaxUs = Wire.nonNull(builder.holdMaxUs, "hold_max_us");
        if (!builder.holdTotalUsSet) throw new IllegalArgumentException("hold_total_us is required");
        this.holdTotalUs = Wire.nonNull(builder.holdTotalUs, "hold_total_us");
        if (!builder.siteSet) throw new IllegalArgumentException("site is required");
        this.site = Wire.nonNull(builder.site, "site");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 acquisitions() { return acquisitions; }
    public UInt64 holdMaxUs() { return holdMaxUs; }
    public UInt64 holdTotalUs() { return holdTotalUs; }
    public String site() { return site; }

    public static ServerStatsLockSite fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockSite");
        Builder builder = builder();
        Object rawAcquisitions = Wire.required(object, "acquisitions");
        builder.acquisitions(Wire.uint64(rawAcquisitions, "ServerStatsLockSite.acquisitions"));
        Object rawHoldMaxUs = Wire.required(object, "hold_max_us");
        builder.holdMaxUs(Wire.uint64(rawHoldMaxUs, "ServerStatsLockSite.hold_max_us"));
        Object rawHoldTotalUs = Wire.required(object, "hold_total_us");
        builder.holdTotalUs(Wire.uint64(rawHoldTotalUs, "ServerStatsLockSite.hold_total_us"));
        Object rawSite = Wire.required(object, "site");
        builder.site(Wire.string(rawSite, "ServerStatsLockSite.site"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "acquisitions", acquisitions);
        Wire.put(object, "hold_max_us", holdMaxUs);
        Wire.put(object, "hold_total_us", holdTotalUs);
        Wire.put(object, "site", site);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockSite that)) return false;
        return Objects.equals(acquisitions, that.acquisitions) && Objects.equals(holdMaxUs, that.holdMaxUs) && Objects.equals(holdTotalUs, that.holdTotalUs) && Objects.equals(site, that.site);
    }

    @Override
    public int hashCode() { return Objects.hash(acquisitions, holdMaxUs, holdTotalUs, site); }

    @Override
    public String toString() { return "ServerStatsLockSite" + toWire(); }

    public static final class Builder {
        private UInt64 acquisitions;
        private boolean acquisitionsSet;
        private UInt64 holdMaxUs;
        private boolean holdMaxUsSet;
        private UInt64 holdTotalUs;
        private boolean holdTotalUsSet;
        private String site;
        private boolean siteSet;

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
        public ServerStatsLockSite build() { return new ServerStatsLockSite(this); }
    }
}

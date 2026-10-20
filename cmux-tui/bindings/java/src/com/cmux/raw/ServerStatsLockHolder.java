// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockHolder implements WireValue {
    private final UInt64 heldForUs;
    private final String site;

    private ServerStatsLockHolder(Builder builder) {
        if (!builder.heldForUsSet) throw new IllegalArgumentException("held_for_us is required");
        this.heldForUs = Wire.nonNull(builder.heldForUs, "held_for_us");
        if (!builder.siteSet) throw new IllegalArgumentException("site is required");
        this.site = Wire.nonNull(builder.site, "site");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 heldForUs() { return heldForUs; }
    public String site() { return site; }

    public static ServerStatsLockHolder fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockHolder");
        Builder builder = builder();
        Object rawHeldForUs = Wire.required(object, "held_for_us");
        builder.heldForUs(Wire.uint64(rawHeldForUs, "ServerStatsLockHolder.held_for_us"));
        Object rawSite = Wire.required(object, "site");
        builder.site(Wire.string(rawSite, "ServerStatsLockHolder.site"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "held_for_us", heldForUs);
        Wire.put(object, "site", site);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockHolder that)) return false;
        return Objects.equals(heldForUs, that.heldForUs) && Objects.equals(site, that.site);
    }

    @Override
    public int hashCode() { return Objects.hash(heldForUs, site); }

    @Override
    public String toString() { return "ServerStatsLockHolder" + toWire(); }

    public static final class Builder {
        private UInt64 heldForUs;
        private boolean heldForUsSet;
        private String site;
        private boolean siteSet;

        public Builder heldForUs(UInt64 value) {
            this.heldForUs = value;
            this.heldForUsSet = true;
            return this;
        }
        public Builder site(String value) {
            this.site = value;
            this.siteSet = true;
            return this;
        }
        public ServerStatsLockHolder build() { return new ServerStatsLockHolder(this); }
    }
}

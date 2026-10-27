// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRequestPathSite implements WireValue {
    private final String kind;
    private final String site;

    private ServerStatsRequestPathSite(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.siteSet) throw new IllegalArgumentException("site is required");
        this.site = Wire.nonNull(builder.site, "site");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return kind; }
    public String site() { return site; }

    public static ServerStatsRequestPathSite fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRequestPathSite");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerStatsRequestPathSite.kind"));
        Object rawSite = Wire.required(object, "site");
        builder.site(Wire.string(rawSite, "ServerStatsRequestPathSite.site"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "site", site);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRequestPathSite that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(site, that.site);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, site); }

    @Override
    public String toString() { return "ServerStatsRequestPathSite" + toWire(); }

    public static final class Builder {
        private String kind;
        private boolean kindSet;
        private String site;
        private boolean siteSet;

        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder site(String value) {
            this.site = value;
            this.siteSet = true;
            return this;
        }
        public ServerStatsRequestPathSite build() { return new ServerStatsRequestPathSite(this); }
    }
}

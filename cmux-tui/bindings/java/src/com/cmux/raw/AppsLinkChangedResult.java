// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsLinkChangedResult implements WireValue {
    private final UInt64 servers;

    private AppsLinkChangedResult(Builder builder) {
        if (!builder.serversSet) throw new IllegalArgumentException("servers is required");
        this.servers = Wire.nonNull(builder.servers, "servers");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 servers() { return servers; }

    public static AppsLinkChangedResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsLinkChangedResult");
        Builder builder = builder();
        Object rawServers = Wire.required(object, "servers");
        builder.servers(Wire.uint64(rawServers, "AppsLinkChangedResult.servers"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "servers", servers);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsLinkChangedResult that)) return false;
        return Objects.equals(servers, that.servers);
    }

    @Override
    public int hashCode() { return Objects.hash(servers); }

    @Override
    public String toString() { return "AppsLinkChangedResult" + toWire(); }

    public static final class Builder {
        private UInt64 servers;
        private boolean serversSet;

        public Builder servers(UInt64 value) {
            this.servers = value;
            this.serversSet = true;
            return this;
        }
        public AppsLinkChangedResult build() { return new AppsLinkChangedResult(this); }
    }
}

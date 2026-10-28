// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMemoryOutbound implements WireValue {
    private final UInt64 budgets;
    private final UInt64 connections;
    private final UInt64 controlRetainedBytes;
    private final UInt64 graphicCacheBytes;
    private final UInt64 graphicCacheEntries;
    private final UInt64 retainedBytes;

    private ServerStatsMemoryOutbound(Builder builder) {
        if (!builder.budgetsSet) throw new IllegalArgumentException("budgets is required");
        this.budgets = Wire.nonNull(builder.budgets, "budgets");
        if (!builder.connectionsSet) throw new IllegalArgumentException("connections is required");
        this.connections = Wire.nonNull(builder.connections, "connections");
        if (!builder.controlRetainedBytesSet) throw new IllegalArgumentException("control_retained_bytes is required");
        this.controlRetainedBytes = Wire.nonNull(builder.controlRetainedBytes, "control_retained_bytes");
        if (!builder.graphicCacheBytesSet) throw new IllegalArgumentException("graphic_cache_bytes is required");
        this.graphicCacheBytes = Wire.nonNull(builder.graphicCacheBytes, "graphic_cache_bytes");
        if (!builder.graphicCacheEntriesSet) throw new IllegalArgumentException("graphic_cache_entries is required");
        this.graphicCacheEntries = Wire.nonNull(builder.graphicCacheEntries, "graphic_cache_entries");
        if (!builder.retainedBytesSet) throw new IllegalArgumentException("retained_bytes is required");
        this.retainedBytes = Wire.nonNull(builder.retainedBytes, "retained_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 budgets() { return budgets; }
    public UInt64 connections() { return connections; }
    public UInt64 controlRetainedBytes() { return controlRetainedBytes; }
    public UInt64 graphicCacheBytes() { return graphicCacheBytes; }
    public UInt64 graphicCacheEntries() { return graphicCacheEntries; }
    public UInt64 retainedBytes() { return retainedBytes; }

    public static ServerStatsMemoryOutbound fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMemoryOutbound");
        Builder builder = builder();
        Object rawBudgets = Wire.required(object, "budgets");
        builder.budgets(Wire.uint64(rawBudgets, "ServerStatsMemoryOutbound.budgets"));
        Object rawConnections = Wire.required(object, "connections");
        builder.connections(Wire.uint64(rawConnections, "ServerStatsMemoryOutbound.connections"));
        Object rawControlRetainedBytes = Wire.required(object, "control_retained_bytes");
        builder.controlRetainedBytes(Wire.uint64(rawControlRetainedBytes, "ServerStatsMemoryOutbound.control_retained_bytes"));
        Object rawGraphicCacheBytes = Wire.required(object, "graphic_cache_bytes");
        builder.graphicCacheBytes(Wire.uint64(rawGraphicCacheBytes, "ServerStatsMemoryOutbound.graphic_cache_bytes"));
        Object rawGraphicCacheEntries = Wire.required(object, "graphic_cache_entries");
        builder.graphicCacheEntries(Wire.uint64(rawGraphicCacheEntries, "ServerStatsMemoryOutbound.graphic_cache_entries"));
        Object rawRetainedBytes = Wire.required(object, "retained_bytes");
        builder.retainedBytes(Wire.uint64(rawRetainedBytes, "ServerStatsMemoryOutbound.retained_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "budgets", budgets);
        Wire.put(object, "connections", connections);
        Wire.put(object, "control_retained_bytes", controlRetainedBytes);
        Wire.put(object, "graphic_cache_bytes", graphicCacheBytes);
        Wire.put(object, "graphic_cache_entries", graphicCacheEntries);
        Wire.put(object, "retained_bytes", retainedBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMemoryOutbound that)) return false;
        return Objects.equals(budgets, that.budgets) && Objects.equals(connections, that.connections) && Objects.equals(controlRetainedBytes, that.controlRetainedBytes) && Objects.equals(graphicCacheBytes, that.graphicCacheBytes) && Objects.equals(graphicCacheEntries, that.graphicCacheEntries) && Objects.equals(retainedBytes, that.retainedBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(budgets, connections, controlRetainedBytes, graphicCacheBytes, graphicCacheEntries, retainedBytes); }

    @Override
    public String toString() { return "ServerStatsMemoryOutbound" + toWire(); }

    public static final class Builder {
        private UInt64 budgets;
        private boolean budgetsSet;
        private UInt64 connections;
        private boolean connectionsSet;
        private UInt64 controlRetainedBytes;
        private boolean controlRetainedBytesSet;
        private UInt64 graphicCacheBytes;
        private boolean graphicCacheBytesSet;
        private UInt64 graphicCacheEntries;
        private boolean graphicCacheEntriesSet;
        private UInt64 retainedBytes;
        private boolean retainedBytesSet;

        public Builder budgets(UInt64 value) {
            this.budgets = value;
            this.budgetsSet = true;
            return this;
        }
        public Builder connections(UInt64 value) {
            this.connections = value;
            this.connectionsSet = true;
            return this;
        }
        public Builder controlRetainedBytes(UInt64 value) {
            this.controlRetainedBytes = value;
            this.controlRetainedBytesSet = true;
            return this;
        }
        public Builder graphicCacheBytes(UInt64 value) {
            this.graphicCacheBytes = value;
            this.graphicCacheBytesSet = true;
            return this;
        }
        public Builder graphicCacheEntries(UInt64 value) {
            this.graphicCacheEntries = value;
            this.graphicCacheEntriesSet = true;
            return this;
        }
        public Builder retainedBytes(UInt64 value) {
            this.retainedBytes = value;
            this.retainedBytesSet = true;
            return this;
        }
        public ServerStatsMemoryOutbound build() { return new ServerStatsMemoryOutbound(this); }
    }
}

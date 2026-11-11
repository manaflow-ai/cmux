// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRegistryReads implements WireValue {
    private final UInt64 committedReadFailures;
    private final UInt64 fallbackFailures;
    private final UInt64 listFallbacks;

    private ServerStatsRegistryReads(Builder builder) {
        if (!builder.committedReadFailuresSet) throw new IllegalArgumentException("committed_read_failures is required");
        this.committedReadFailures = Wire.nonNull(builder.committedReadFailures, "committed_read_failures");
        if (!builder.fallbackFailuresSet) throw new IllegalArgumentException("fallback_failures is required");
        this.fallbackFailures = Wire.nonNull(builder.fallbackFailures, "fallback_failures");
        if (!builder.listFallbacksSet) throw new IllegalArgumentException("list_fallbacks is required");
        this.listFallbacks = Wire.nonNull(builder.listFallbacks, "list_fallbacks");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 committedReadFailures() { return committedReadFailures; }
    public UInt64 fallbackFailures() { return fallbackFailures; }
    public UInt64 listFallbacks() { return listFallbacks; }

    public static ServerStatsRegistryReads fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRegistryReads");
        Builder builder = builder();
        Object rawCommittedReadFailures = Wire.required(object, "committed_read_failures");
        builder.committedReadFailures(Wire.uint64(rawCommittedReadFailures, "ServerStatsRegistryReads.committed_read_failures"));
        Object rawFallbackFailures = Wire.required(object, "fallback_failures");
        builder.fallbackFailures(Wire.uint64(rawFallbackFailures, "ServerStatsRegistryReads.fallback_failures"));
        Object rawListFallbacks = Wire.required(object, "list_fallbacks");
        builder.listFallbacks(Wire.uint64(rawListFallbacks, "ServerStatsRegistryReads.list_fallbacks"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "committed_read_failures", committedReadFailures);
        Wire.put(object, "fallback_failures", fallbackFailures);
        Wire.put(object, "list_fallbacks", listFallbacks);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRegistryReads that)) return false;
        return Objects.equals(committedReadFailures, that.committedReadFailures) && Objects.equals(fallbackFailures, that.fallbackFailures) && Objects.equals(listFallbacks, that.listFallbacks);
    }

    @Override
    public int hashCode() { return Objects.hash(committedReadFailures, fallbackFailures, listFallbacks); }

    @Override
    public String toString() { return "ServerStatsRegistryReads" + toWire(); }

    public static final class Builder {
        private UInt64 committedReadFailures;
        private boolean committedReadFailuresSet;
        private UInt64 fallbackFailures;
        private boolean fallbackFailuresSet;
        private UInt64 listFallbacks;
        private boolean listFallbacksSet;

        public Builder committedReadFailures(UInt64 value) {
            this.committedReadFailures = value;
            this.committedReadFailuresSet = true;
            return this;
        }
        public Builder fallbackFailures(UInt64 value) {
            this.fallbackFailures = value;
            this.fallbackFailuresSet = true;
            return this;
        }
        public Builder listFallbacks(UInt64 value) {
            this.listFallbacks = value;
            this.listFallbacksSet = true;
            return this;
        }
        public ServerStatsRegistryReads build() { return new ServerStatsRegistryReads(this); }
    }
}

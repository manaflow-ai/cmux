// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsCommandRow implements WireValue {
    private final UInt64 count;
    private final List<UInt64> hist;
    private final String kind;
    private final UInt64 maxNs;
    private final String name;
    private final UInt64 totalNs;

    private ServerStatsCommandRow(Builder builder) {
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = Wire.nonNull(builder.count, "count");
        if (!builder.histSet) throw new IllegalArgumentException("hist is required");
        this.hist = List.copyOf(Wire.nonNull(builder.hist, "hist"));
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.maxNsSet) throw new IllegalArgumentException("max_ns is required");
        this.maxNs = Wire.nonNull(builder.maxNs, "max_ns");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.totalNsSet) throw new IllegalArgumentException("total_ns is required");
        this.totalNs = Wire.nonNull(builder.totalNs, "total_ns");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 count() { return count; }
    public List<UInt64> hist() { return hist; }
    public String kind() { return kind; }
    public UInt64 maxNs() { return maxNs; }
    public String name() { return name; }
    public UInt64 totalNs() { return totalNs; }

    public static ServerStatsCommandRow fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsCommandRow");
        Builder builder = builder();
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint64(rawCount, "ServerStatsCommandRow.count"));
        Object rawHist = Wire.required(object, "hist");
        builder.hist(Wire.array(rawHist, "ServerStatsCommandRow.hist", item -> Wire.uint64(item, "ServerStatsCommandRow.hist item")));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerStatsCommandRow.kind"));
        Object rawMaxNs = Wire.required(object, "max_ns");
        builder.maxNs(Wire.uint64(rawMaxNs, "ServerStatsCommandRow.max_ns"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "ServerStatsCommandRow.name"));
        Object rawTotalNs = Wire.required(object, "total_ns");
        builder.totalNs(Wire.uint64(rawTotalNs, "ServerStatsCommandRow.total_ns"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "count", count);
        Wire.put(object, "hist", hist);
        Wire.put(object, "kind", kind);
        Wire.put(object, "max_ns", maxNs);
        Wire.put(object, "name", name);
        Wire.put(object, "total_ns", totalNs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsCommandRow that)) return false;
        return Objects.equals(count, that.count) && Objects.equals(hist, that.hist) && Objects.equals(kind, that.kind) && Objects.equals(maxNs, that.maxNs) && Objects.equals(name, that.name) && Objects.equals(totalNs, that.totalNs);
    }

    @Override
    public int hashCode() { return Objects.hash(count, hist, kind, maxNs, name, totalNs); }

    @Override
    public String toString() { return "ServerStatsCommandRow" + toWire(); }

    public static final class Builder {
        private UInt64 count;
        private boolean countSet;
        private List<UInt64> hist;
        private boolean histSet;
        private String kind;
        private boolean kindSet;
        private UInt64 maxNs;
        private boolean maxNsSet;
        private String name;
        private boolean nameSet;
        private UInt64 totalNs;
        private boolean totalNsSet;

        public Builder count(UInt64 value) {
            this.count = value;
            this.countSet = true;
            return this;
        }
        public Builder hist(List<UInt64> value) {
            this.hist = value;
            this.histSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder maxNs(UInt64 value) {
            this.maxNs = value;
            this.maxNsSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder totalNs(UInt64 value) {
            this.totalNs = value;
            this.totalNsSet = true;
            return this;
        }
        public ServerStatsCommandRow build() { return new ServerStatsCommandRow(this); }
    }
}

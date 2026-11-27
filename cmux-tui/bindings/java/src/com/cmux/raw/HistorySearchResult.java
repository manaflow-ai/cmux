// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HistorySearchResult implements WireValue {
    private final List<HistorySearchHit> hits;
    private final UInt64 tookUs;

    private HistorySearchResult(Builder builder) {
        if (!builder.hitsSet) throw new IllegalArgumentException("hits is required");
        this.hits = List.copyOf(Wire.nonNull(builder.hits, "hits"));
        if (!builder.tookUsSet) throw new IllegalArgumentException("took_us is required");
        this.tookUs = Wire.nonNull(builder.tookUs, "took_us");
    }

    public static Builder builder() { return new Builder(); }

    public List<HistorySearchHit> hits() { return hits; }
    public UInt64 tookUs() { return tookUs; }

    public static HistorySearchResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HistorySearchResult");
        Builder builder = builder();
        Object rawHits = Wire.required(object, "hits");
        builder.hits(Wire.array(rawHits, "HistorySearchResult.hits", item -> HistorySearchHit.fromWire(item)));
        Object rawTookUs = Wire.required(object, "took_us");
        builder.tookUs(Wire.uint64(rawTookUs, "HistorySearchResult.took_us"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "hits", hits);
        Wire.put(object, "took_us", tookUs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HistorySearchResult that)) return false;
        return Objects.equals(hits, that.hits) && Objects.equals(tookUs, that.tookUs);
    }

    @Override
    public int hashCode() { return Objects.hash(hits, tookUs); }

    @Override
    public String toString() { return "HistorySearchResult" + toWire(); }

    public static final class Builder {
        private List<HistorySearchHit> hits;
        private boolean hitsSet;
        private UInt64 tookUs;
        private boolean tookUsSet;

        public Builder hits(List<HistorySearchHit> value) {
            this.hits = value;
            this.hitsSet = true;
            return this;
        }
        public Builder tookUs(UInt64 value) {
            this.tookUs = value;
            this.tookUsSet = true;
            return this;
        }
        public HistorySearchResult build() { return new HistorySearchResult(this); }
    }
}

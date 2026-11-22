// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationSearchResult implements WireValue {
    private final List<ConversationSearchHit> hits;

    private ConversationSearchResult(Builder builder) {
        if (!builder.hitsSet) throw new IllegalArgumentException("hits is required");
        this.hits = List.copyOf(Wire.nonNull(builder.hits, "hits"));
    }

    public static Builder builder() { return new Builder(); }

    public List<ConversationSearchHit> hits() { return hits; }

    public static ConversationSearchResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationSearchResult");
        Builder builder = builder();
        Object rawHits = Wire.required(object, "hits");
        builder.hits(Wire.array(rawHits, "ConversationSearchResult.hits", item -> ConversationSearchHit.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "hits", hits);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationSearchResult that)) return false;
        return Objects.equals(hits, that.hits);
    }

    @Override
    public int hashCode() { return Objects.hash(hits); }

    @Override
    public String toString() { return "ConversationSearchResult" + toWire(); }

    public static final class Builder {
        private List<ConversationSearchHit> hits;
        private boolean hitsSet;

        public Builder hits(List<ConversationSearchHit> value) {
            this.hits = value;
            this.hitsSet = true;
            return this;
        }
        public ConversationSearchResult build() { return new ConversationSearchResult(this); }
    }
}

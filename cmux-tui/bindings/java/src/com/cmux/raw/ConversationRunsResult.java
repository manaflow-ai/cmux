// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationRunsResult implements WireValue {
    private final boolean hasMore;
    private final List<Object> runs;

    private ConversationRunsResult(Builder builder) {
        if (!builder.hasMoreSet) throw new IllegalArgumentException("has_more is required");
        this.hasMore = builder.hasMore;
        if (!builder.runsSet) throw new IllegalArgumentException("runs is required");
        this.runs = List.copyOf(Wire.nonNull(builder.runs, "runs"));
    }

    public static Builder builder() { return new Builder(); }

    public boolean hasMore() { return hasMore; }
    public List<Object> runs() { return runs; }

    public static ConversationRunsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationRunsResult");
        Builder builder = builder();
        Object rawHasMore = Wire.required(object, "has_more");
        builder.hasMore(Wire.bool(rawHasMore, "ConversationRunsResult.has_more"));
        Object rawRuns = Wire.required(object, "runs");
        builder.runs(Wire.array(rawRuns, "ConversationRunsResult.runs", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "has_more", hasMore);
        Wire.put(object, "runs", runs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationRunsResult that)) return false;
        return Objects.equals(hasMore, that.hasMore) && Objects.equals(runs, that.runs);
    }

    @Override
    public int hashCode() { return Objects.hash(hasMore, runs); }

    @Override
    public String toString() { return "ConversationRunsResult" + toWire(); }

    public static final class Builder {
        private Boolean hasMore;
        private boolean hasMoreSet;
        private List<Object> runs;
        private boolean runsSet;

        public Builder hasMore(boolean value) {
            this.hasMore = value;
            this.hasMoreSet = true;
            return this;
        }
        public Builder runs(List<Object> value) {
            this.runs = value;
            this.runsSet = true;
            return this;
        }
        public ConversationRunsResult build() { return new ConversationRunsResult(this); }
    }
}

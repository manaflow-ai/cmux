// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationRunResult implements WireValue {
    private final boolean hasMore;
    private final Object run;
    private final List<Object> steps;

    private ConversationRunResult(Builder builder) {
        if (!builder.hasMoreSet) throw new IllegalArgumentException("has_more is required");
        this.hasMore = builder.hasMore;
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = builder.run == null ? null : Wire.immutableJson(builder.run);
        if (!builder.stepsSet) throw new IllegalArgumentException("steps is required");
        this.steps = List.copyOf(Wire.nonNull(builder.steps, "steps"));
    }

    public static Builder builder() { return new Builder(); }

    public boolean hasMore() { return hasMore; }
    public Object run() { return run; }
    public List<Object> steps() { return steps; }

    public static ConversationRunResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationRunResult");
        Builder builder = builder();
        Object rawHasMore = Wire.required(object, "has_more");
        builder.hasMore(Wire.bool(rawHasMore, "ConversationRunResult.has_more"));
        Object rawRun = Wire.required(object, "run");
        builder.run(rawRun == null ? null : Wire.immutableJson(rawRun));
        Object rawSteps = Wire.required(object, "steps");
        builder.steps(Wire.array(rawSteps, "ConversationRunResult.steps", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "has_more", hasMore);
        Wire.put(object, "run", run);
        Wire.put(object, "steps", steps);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationRunResult that)) return false;
        return Objects.equals(hasMore, that.hasMore) && Objects.equals(run, that.run) && Objects.equals(steps, that.steps);
    }

    @Override
    public int hashCode() { return Objects.hash(hasMore, run, steps); }

    @Override
    public String toString() { return "ConversationRunResult" + toWire(); }

    public static final class Builder {
        private Boolean hasMore;
        private boolean hasMoreSet;
        private Object run;
        private boolean runSet;
        private List<Object> steps;
        private boolean stepsSet;

        public Builder hasMore(boolean value) {
            this.hasMore = value;
            this.hasMoreSet = true;
            return this;
        }
        public Builder run(Object value) {
            this.run = value;
            this.runSet = true;
            return this;
        }
        public Builder steps(List<Object> value) {
            this.steps = value;
            this.stepsSet = true;
            return this;
        }
        public ConversationRunResult build() { return new ConversationRunResult(this); }
    }
}

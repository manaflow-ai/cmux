// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable jobs-changed event. Protocol v12; streams: subscribe. */
public final class JobsChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final List<LongJob> jobs;

    private JobsChangedEvent(Builder builder) {
        if (!builder.jobsSet) throw new IllegalArgumentException("jobs is required");
        this.jobs = List.copyOf(Wire.nonNull(builder.jobs, "jobs"));
    }

    public static Builder builder() { return new Builder(); }

    public List<LongJob> jobs() { return jobs; }
    @Override public String event() { return "jobs-changed"; }

    public static JobsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "JobsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "jobs-changed", "JobsChangedEvent.event");
        Object rawJobs = Wire.required(object, "jobs");
        builder.jobs(Wire.array(rawJobs, "JobsChangedEvent.jobs", item -> LongJob.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "jobs-changed");
        Wire.put(object, "jobs", jobs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof JobsChangedEvent that)) return false;
        return Objects.equals(jobs, that.jobs);
    }

    @Override
    public int hashCode() { return Objects.hash(jobs); }

    @Override
    public String toString() { return "JobsChangedEvent" + toWire(); }

    public static final class Builder {
        private List<LongJob> jobs;
        private boolean jobsSet;

        public Builder jobs(List<LongJob> value) {
            this.jobs = value;
            this.jobsSet = true;
            return this;
        }
        public JobsChangedEvent build() { return new JobsChangedEvent(this); }
    }
}

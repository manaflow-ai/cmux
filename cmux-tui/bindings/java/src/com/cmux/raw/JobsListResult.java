// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class JobsListResult implements WireValue {
    private final List<LongJob> jobs;

    private JobsListResult(Builder builder) {
        if (!builder.jobsSet) throw new IllegalArgumentException("jobs is required");
        this.jobs = List.copyOf(Wire.nonNull(builder.jobs, "jobs"));
    }

    public static Builder builder() { return new Builder(); }

    public List<LongJob> jobs() { return jobs; }

    public static JobsListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "JobsListResult");
        Builder builder = builder();
        Object rawJobs = Wire.required(object, "jobs");
        builder.jobs(Wire.array(rawJobs, "JobsListResult.jobs", item -> LongJob.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "jobs", jobs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof JobsListResult that)) return false;
        return Objects.equals(jobs, that.jobs);
    }

    @Override
    public int hashCode() { return Objects.hash(jobs); }

    @Override
    public String toString() { return "JobsListResult" + toWire(); }

    public static final class Builder {
        private List<LongJob> jobs;
        private boolean jobsSet;

        public Builder jobs(List<LongJob> value) {
            this.jobs = value;
            this.jobsSet = true;
            return this;
        }
        public JobsListResult build() { return new JobsListResult(this); }
    }
}

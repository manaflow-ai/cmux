// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentUpdateApplyResult implements WireValue {
    private final Field<String> machine;
    private final List<AgentUpdateOutcome> results;
    private final UInt64 threadsAfterTurn;
    private final Field<String> threadsError;
    private final UInt64 threadsFailed;
    private final UInt64 threadsRestarted;

    private AgentUpdateApplyResult(Builder builder) {
        this.machine = builder.machine;
        if (!builder.resultsSet) throw new IllegalArgumentException("results is required");
        this.results = List.copyOf(Wire.nonNull(builder.results, "results"));
        if (!builder.threadsAfterTurnSet) throw new IllegalArgumentException("threads_after_turn is required");
        this.threadsAfterTurn = Wire.nonNull(builder.threadsAfterTurn, "threads_after_turn");
        this.threadsError = builder.threadsError;
        if (!builder.threadsFailedSet) throw new IllegalArgumentException("threads_failed is required");
        this.threadsFailed = Wire.nonNull(builder.threadsFailed, "threads_failed");
        if (!builder.threadsRestartedSet) throw new IllegalArgumentException("threads_restarted is required");
        this.threadsRestarted = Wire.nonNull(builder.threadsRestarted, "threads_restarted");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> machine() { return machine; }
    public List<AgentUpdateOutcome> results() { return results; }
    public UInt64 threadsAfterTurn() { return threadsAfterTurn; }
    public Field<String> threadsError() { return threadsError; }
    public UInt64 threadsFailed() { return threadsFailed; }
    public UInt64 threadsRestarted() { return threadsRestarted; }

    public static AgentUpdateApplyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentUpdateApplyResult");
        Builder builder = builder();
        Object rawMachine = Wire.optional(object, "machine");
        if (!Wire.isMissing(rawMachine)) {
            builder.machine(Wire.string(rawMachine, "AgentUpdateApplyResult.machine"));
        }
        Object rawResults = Wire.required(object, "results");
        builder.results(Wire.array(rawResults, "AgentUpdateApplyResult.results", item -> AgentUpdateOutcome.fromWire(item)));
        Object rawThreadsAfterTurn = Wire.required(object, "threads_after_turn");
        builder.threadsAfterTurn(Wire.uint64(rawThreadsAfterTurn, "AgentUpdateApplyResult.threads_after_turn"));
        Object rawThreadsError = Wire.optional(object, "threads_error");
        if (!Wire.isMissing(rawThreadsError)) {
            builder.threadsError(Wire.string(rawThreadsError, "AgentUpdateApplyResult.threads_error"));
        }
        Object rawThreadsFailed = Wire.required(object, "threads_failed");
        builder.threadsFailed(Wire.uint64(rawThreadsFailed, "AgentUpdateApplyResult.threads_failed"));
        Object rawThreadsRestarted = Wire.required(object, "threads_restarted");
        builder.threadsRestarted(Wire.uint64(rawThreadsRestarted, "AgentUpdateApplyResult.threads_restarted"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "machine", machine);
        Wire.put(object, "results", results);
        Wire.put(object, "threads_after_turn", threadsAfterTurn);
        Wire.put(object, "threads_error", threadsError);
        Wire.put(object, "threads_failed", threadsFailed);
        Wire.put(object, "threads_restarted", threadsRestarted);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentUpdateApplyResult that)) return false;
        return Objects.equals(machine, that.machine) && Objects.equals(results, that.results) && Objects.equals(threadsAfterTurn, that.threadsAfterTurn) && Objects.equals(threadsError, that.threadsError) && Objects.equals(threadsFailed, that.threadsFailed) && Objects.equals(threadsRestarted, that.threadsRestarted);
    }

    @Override
    public int hashCode() { return Objects.hash(machine, results, threadsAfterTurn, threadsError, threadsFailed, threadsRestarted); }

    @Override
    public String toString() { return "AgentUpdateApplyResult" + toWire(); }

    public static final class Builder {
        private Field<String> machine = Field.omitted();
        private List<AgentUpdateOutcome> results;
        private boolean resultsSet;
        private UInt64 threadsAfterTurn;
        private boolean threadsAfterTurnSet;
        private Field<String> threadsError = Field.omitted();
        private UInt64 threadsFailed;
        private boolean threadsFailedSet;
        private UInt64 threadsRestarted;
        private boolean threadsRestartedSet;

        public Builder machine(String value) {
            this.machine = Field.of(value);
            return this;
        }
        public Builder results(List<AgentUpdateOutcome> value) {
            this.results = value;
            this.resultsSet = true;
            return this;
        }
        public Builder threadsAfterTurn(UInt64 value) {
            this.threadsAfterTurn = value;
            this.threadsAfterTurnSet = true;
            return this;
        }
        public Builder threadsError(String value) {
            this.threadsError = Field.of(value);
            return this;
        }
        public Builder threadsFailed(UInt64 value) {
            this.threadsFailed = value;
            this.threadsFailedSet = true;
            return this;
        }
        public Builder threadsRestarted(UInt64 value) {
            this.threadsRestarted = value;
            this.threadsRestartedSet = true;
            return this;
        }
        public AgentUpdateApplyResult build() { return new AgentUpdateApplyResult(this); }
    }
}

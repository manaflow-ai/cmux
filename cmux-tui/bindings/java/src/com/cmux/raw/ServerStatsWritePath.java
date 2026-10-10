// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsWritePath implements WireValue {
    private final UInt64 effectIntentBatches;
    private final UInt64 effectIntentFailures;
    private final UInt64 effectIntents;
    private final UInt64 requestEffectCommits;
    private final UInt64 writerRegistryLocks;

    private ServerStatsWritePath(Builder builder) {
        if (!builder.effectIntentBatchesSet) throw new IllegalArgumentException("effect_intent_batches is required");
        this.effectIntentBatches = Wire.nonNull(builder.effectIntentBatches, "effect_intent_batches");
        if (!builder.effectIntentFailuresSet) throw new IllegalArgumentException("effect_intent_failures is required");
        this.effectIntentFailures = Wire.nonNull(builder.effectIntentFailures, "effect_intent_failures");
        if (!builder.effectIntentsSet) throw new IllegalArgumentException("effect_intents is required");
        this.effectIntents = Wire.nonNull(builder.effectIntents, "effect_intents");
        if (!builder.requestEffectCommitsSet) throw new IllegalArgumentException("request_effect_commits is required");
        this.requestEffectCommits = Wire.nonNull(builder.requestEffectCommits, "request_effect_commits");
        if (!builder.writerRegistryLocksSet) throw new IllegalArgumentException("writer_registry_locks is required");
        this.writerRegistryLocks = Wire.nonNull(builder.writerRegistryLocks, "writer_registry_locks");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 effectIntentBatches() { return effectIntentBatches; }
    public UInt64 effectIntentFailures() { return effectIntentFailures; }
    public UInt64 effectIntents() { return effectIntents; }
    public UInt64 requestEffectCommits() { return requestEffectCommits; }
    public UInt64 writerRegistryLocks() { return writerRegistryLocks; }

    public static ServerStatsWritePath fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsWritePath");
        Builder builder = builder();
        Object rawEffectIntentBatches = Wire.required(object, "effect_intent_batches");
        builder.effectIntentBatches(Wire.uint64(rawEffectIntentBatches, "ServerStatsWritePath.effect_intent_batches"));
        Object rawEffectIntentFailures = Wire.required(object, "effect_intent_failures");
        builder.effectIntentFailures(Wire.uint64(rawEffectIntentFailures, "ServerStatsWritePath.effect_intent_failures"));
        Object rawEffectIntents = Wire.required(object, "effect_intents");
        builder.effectIntents(Wire.uint64(rawEffectIntents, "ServerStatsWritePath.effect_intents"));
        Object rawRequestEffectCommits = Wire.required(object, "request_effect_commits");
        builder.requestEffectCommits(Wire.uint64(rawRequestEffectCommits, "ServerStatsWritePath.request_effect_commits"));
        Object rawWriterRegistryLocks = Wire.required(object, "writer_registry_locks");
        builder.writerRegistryLocks(Wire.uint64(rawWriterRegistryLocks, "ServerStatsWritePath.writer_registry_locks"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "effect_intent_batches", effectIntentBatches);
        Wire.put(object, "effect_intent_failures", effectIntentFailures);
        Wire.put(object, "effect_intents", effectIntents);
        Wire.put(object, "request_effect_commits", requestEffectCommits);
        Wire.put(object, "writer_registry_locks", writerRegistryLocks);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsWritePath that)) return false;
        return Objects.equals(effectIntentBatches, that.effectIntentBatches) && Objects.equals(effectIntentFailures, that.effectIntentFailures) && Objects.equals(effectIntents, that.effectIntents) && Objects.equals(requestEffectCommits, that.requestEffectCommits) && Objects.equals(writerRegistryLocks, that.writerRegistryLocks);
    }

    @Override
    public int hashCode() { return Objects.hash(effectIntentBatches, effectIntentFailures, effectIntents, requestEffectCommits, writerRegistryLocks); }

    @Override
    public String toString() { return "ServerStatsWritePath" + toWire(); }

    public static final class Builder {
        private UInt64 effectIntentBatches;
        private boolean effectIntentBatchesSet;
        private UInt64 effectIntentFailures;
        private boolean effectIntentFailuresSet;
        private UInt64 effectIntents;
        private boolean effectIntentsSet;
        private UInt64 requestEffectCommits;
        private boolean requestEffectCommitsSet;
        private UInt64 writerRegistryLocks;
        private boolean writerRegistryLocksSet;

        public Builder effectIntentBatches(UInt64 value) {
            this.effectIntentBatches = value;
            this.effectIntentBatchesSet = true;
            return this;
        }
        public Builder effectIntentFailures(UInt64 value) {
            this.effectIntentFailures = value;
            this.effectIntentFailuresSet = true;
            return this;
        }
        public Builder effectIntents(UInt64 value) {
            this.effectIntents = value;
            this.effectIntentsSet = true;
            return this;
        }
        public Builder requestEffectCommits(UInt64 value) {
            this.requestEffectCommits = value;
            this.requestEffectCommitsSet = true;
            return this;
        }
        public Builder writerRegistryLocks(UInt64 value) {
            this.writerRegistryLocks = value;
            this.writerRegistryLocksSet = true;
            return this;
        }
        public ServerStatsWritePath build() { return new ServerStatsWritePath(this); }
    }
}

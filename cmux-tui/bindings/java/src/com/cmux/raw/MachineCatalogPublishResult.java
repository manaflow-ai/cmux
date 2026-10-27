// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineCatalogPublishResult implements WireValue {
    private final boolean replayed;
    private final UInt64 sequence;

    private MachineCatalogPublishResult(Builder builder) {
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.sequenceSet) throw new IllegalArgumentException("sequence is required");
        this.sequence = Wire.nonNull(builder.sequence, "sequence");
    }

    public static Builder builder() { return new Builder(); }

    public boolean replayed() { return replayed; }
    public UInt64 sequence() { return sequence; }

    public static MachineCatalogPublishResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineCatalogPublishResult");
        Builder builder = builder();
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "MachineCatalogPublishResult.replayed"));
        Object rawSequence = Wire.required(object, "sequence");
        builder.sequence(Wire.uint64(rawSequence, "MachineCatalogPublishResult.sequence"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "sequence", sequence);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineCatalogPublishResult that)) return false;
        return Objects.equals(replayed, that.replayed) && Objects.equals(sequence, that.sequence);
    }

    @Override
    public int hashCode() { return Objects.hash(replayed, sequence); }

    @Override
    public String toString() { return "MachineCatalogPublishResult" + toWire(); }

    public static final class Builder {
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 sequence;
        private boolean sequenceSet;

        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder sequence(UInt64 value) {
            this.sequence = value;
            this.sequenceSet = true;
            return this;
        }
        public MachineCatalogPublishResult build() { return new MachineCatalogPublishResult(this); }
    }
}

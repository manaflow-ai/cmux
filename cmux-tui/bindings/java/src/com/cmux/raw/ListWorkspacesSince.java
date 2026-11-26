// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListWorkspacesSince implements WireValue {
    private final String epoch;
    private final UInt64 seq;

    private ListWorkspacesSince(Builder builder) {
        if (!builder.epochSet) throw new IllegalArgumentException("epoch is required");
        this.epoch = Wire.nonNull(builder.epoch, "epoch");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public String epoch() { return epoch; }
    public UInt64 seq() { return seq; }

    public static ListWorkspacesSince fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListWorkspacesSince");
        Builder builder = builder();
        Object rawEpoch = Wire.required(object, "epoch");
        builder.epoch(Wire.string(rawEpoch, "ListWorkspacesSince.epoch"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "ListWorkspacesSince.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "epoch", epoch);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListWorkspacesSince that)) return false;
        return Objects.equals(epoch, that.epoch) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(epoch, seq); }

    @Override
    public String toString() { return "ListWorkspacesSince" + toWire(); }

    public static final class Builder {
        private String epoch;
        private boolean epochSet;
        private UInt64 seq;
        private boolean seqSet;

        public Builder epoch(String value) {
            this.epoch = value;
            this.epochSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public ListWorkspacesSince build() { return new ListWorkspacesSince(this); }
    }
}

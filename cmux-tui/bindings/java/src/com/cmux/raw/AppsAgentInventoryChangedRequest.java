// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-agent-inventory-changed request. Protocol v12; authority: local-admin. */
public final class AppsAgentInventoryChangedRequest implements WireValue {
    private final UInt64 demandSequence;

    private AppsAgentInventoryChangedRequest(Builder builder) {
        if (!builder.demandSequenceSet) throw new IllegalArgumentException("demand_sequence is required");
        this.demandSequence = Wire.nonNull(builder.demandSequence, "demand_sequence");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 demandSequence() { return demandSequence; }

    public static AppsAgentInventoryChangedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsAgentInventoryChangedRequest");
        Builder builder = builder();
        Object rawDemandSequence = Wire.required(object, "demand_sequence");
        builder.demandSequence(Wire.uint64(rawDemandSequence, "AppsAgentInventoryChangedRequest.demand_sequence"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "demand_sequence", demandSequence);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsAgentInventoryChangedRequest that)) return false;
        return Objects.equals(demandSequence, that.demandSequence);
    }

    @Override
    public int hashCode() { return Objects.hash(demandSequence); }

    @Override
    public String toString() { return "AppsAgentInventoryChangedRequest" + toWire(); }

    public static final class Builder {
        private UInt64 demandSequence;
        private boolean demandSequenceSet;

        public Builder demandSequence(UInt64 value) {
            this.demandSequence = value;
            this.demandSequenceSet = true;
            return this;
        }
        public AppsAgentInventoryChangedRequest build() { return new AppsAgentInventoryChangedRequest(this); }
    }
}

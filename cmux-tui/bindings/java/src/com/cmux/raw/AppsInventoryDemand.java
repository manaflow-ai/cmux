// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsInventoryDemand implements WireValue {
    private final boolean enabled;
    private final UInt64 sequence;

    private AppsInventoryDemand(Builder builder) {
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
        if (!builder.sequenceSet) throw new IllegalArgumentException("sequence is required");
        this.sequence = Wire.nonNull(builder.sequence, "sequence");
    }

    public static Builder builder() { return new Builder(); }

    public boolean enabled() { return enabled; }
    public UInt64 sequence() { return sequence; }

    public static AppsInventoryDemand fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsInventoryDemand");
        Builder builder = builder();
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "AppsInventoryDemand.enabled"));
        Object rawSequence = Wire.required(object, "sequence");
        builder.sequence(Wire.uint64(rawSequence, "AppsInventoryDemand.sequence"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "sequence", sequence);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsInventoryDemand that)) return false;
        return Objects.equals(enabled, that.enabled) && Objects.equals(sequence, that.sequence);
    }

    @Override
    public int hashCode() { return Objects.hash(enabled, sequence); }

    @Override
    public String toString() { return "AppsInventoryDemand" + toWire(); }

    public static final class Builder {
        private Boolean enabled;
        private boolean enabledSet;
        private UInt64 sequence;
        private boolean sequenceSet;

        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public Builder sequence(UInt64 value) {
            this.sequence = value;
            this.sequenceSet = true;
            return this;
        }
        public AppsInventoryDemand build() { return new AppsInventoryDemand(this); }
    }
}

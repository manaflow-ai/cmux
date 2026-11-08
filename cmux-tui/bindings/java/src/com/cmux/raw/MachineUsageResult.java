// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineUsageResult implements WireValue {
    private final MachineUsage usage;

    private MachineUsageResult(Builder builder) {
        if (!builder.usageSet) throw new IllegalArgumentException("usage is required");
        this.usage = builder.usage;
    }

    public static Builder builder() { return new Builder(); }

    public MachineUsage usage() { return usage; }

    public static MachineUsageResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineUsageResult");
        Builder builder = builder();
        Object rawUsage = Wire.required(object, "usage");
        builder.usage(rawUsage == null ? null : MachineUsage.fromWire(rawUsage));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "usage", usage);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineUsageResult that)) return false;
        return Objects.equals(usage, that.usage);
    }

    @Override
    public int hashCode() { return Objects.hash(usage); }

    @Override
    public String toString() { return "MachineUsageResult" + toWire(); }

    public static final class Builder {
        private MachineUsage usage;
        private boolean usageSet;

        public Builder usage(MachineUsage value) {
            this.usage = value;
            this.usageSet = true;
            return this;
        }
        public MachineUsageResult build() { return new MachineUsageResult(this); }
    }
}

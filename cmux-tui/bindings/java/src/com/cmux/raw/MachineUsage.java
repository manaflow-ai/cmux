// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineUsage implements WireValue {
    private final double apiEquivalentUsd;
    private final String asOf;
    private final long periodDays;
    private final UInt64 totalTokens;
    private final String vmId;

    private MachineUsage(Builder builder) {
        if (!builder.apiEquivalentUsdSet) throw new IllegalArgumentException("api_equivalent_usd is required");
        this.apiEquivalentUsd = builder.apiEquivalentUsd;
        if (!builder.asOfSet) throw new IllegalArgumentException("as_of is required");
        this.asOf = builder.asOf;
        if (!builder.periodDaysSet) throw new IllegalArgumentException("period_days is required");
        this.periodDays = builder.periodDays;
        if (!builder.totalTokensSet) throw new IllegalArgumentException("total_tokens is required");
        this.totalTokens = Wire.nonNull(builder.totalTokens, "total_tokens");
        if (!builder.vmIdSet) throw new IllegalArgumentException("vm_id is required");
        this.vmId = Wire.nonNull(builder.vmId, "vm_id");
    }

    public static Builder builder() { return new Builder(); }

    public double apiEquivalentUsd() { return apiEquivalentUsd; }
    public String asOf() { return asOf; }
    public long periodDays() { return periodDays; }
    public UInt64 totalTokens() { return totalTokens; }
    public String vmId() { return vmId; }

    public static MachineUsage fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineUsage");
        Builder builder = builder();
        Object rawApiEquivalentUsd = Wire.required(object, "api_equivalent_usd");
        builder.apiEquivalentUsd(Wire.float64(rawApiEquivalentUsd, "MachineUsage.api_equivalent_usd"));
        Object rawAsOf = Wire.required(object, "as_of");
        builder.asOf(rawAsOf == null ? null : Wire.string(rawAsOf, "MachineUsage.as_of"));
        Object rawPeriodDays = Wire.required(object, "period_days");
        builder.periodDays(Wire.uint32(rawPeriodDays, "MachineUsage.period_days"));
        Object rawTotalTokens = Wire.required(object, "total_tokens");
        builder.totalTokens(Wire.uint64(rawTotalTokens, "MachineUsage.total_tokens"));
        Object rawVmId = Wire.required(object, "vm_id");
        builder.vmId(Wire.string(rawVmId, "MachineUsage.vm_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "api_equivalent_usd", apiEquivalentUsd);
        Wire.put(object, "as_of", asOf);
        Wire.put(object, "period_days", periodDays);
        Wire.put(object, "total_tokens", totalTokens);
        Wire.put(object, "vm_id", vmId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineUsage that)) return false;
        return Objects.equals(apiEquivalentUsd, that.apiEquivalentUsd) && Objects.equals(asOf, that.asOf) && Objects.equals(periodDays, that.periodDays) && Objects.equals(totalTokens, that.totalTokens) && Objects.equals(vmId, that.vmId);
    }

    @Override
    public int hashCode() { return Objects.hash(apiEquivalentUsd, asOf, periodDays, totalTokens, vmId); }

    @Override
    public String toString() { return "MachineUsage" + toWire(); }

    public static final class Builder {
        private Double apiEquivalentUsd;
        private boolean apiEquivalentUsdSet;
        private String asOf;
        private boolean asOfSet;
        private Long periodDays;
        private boolean periodDaysSet;
        private UInt64 totalTokens;
        private boolean totalTokensSet;
        private String vmId;
        private boolean vmIdSet;

        public Builder apiEquivalentUsd(double value) {
            this.apiEquivalentUsd = value;
            this.apiEquivalentUsdSet = true;
            return this;
        }
        public Builder asOf(String value) {
            this.asOf = value;
            this.asOfSet = true;
            return this;
        }
        public Builder periodDays(long value) {
            this.periodDays = value;
            this.periodDaysSet = true;
            return this;
        }
        public Builder totalTokens(UInt64 value) {
            this.totalTokens = value;
            this.totalTokensSet = true;
            return this;
        }
        public Builder vmId(String value) {
            this.vmId = value;
            this.vmIdSet = true;
            return this;
        }
        public MachineUsage build() { return new MachineUsage(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskCheckpoints implements WireValue {
    private final UInt64 budgetBytes;
    private final UInt64 bytes;
    private final UInt64 checkpoints;
    private final UInt64 largestBytes;
    private final boolean overBudget;

    private ServerStatsDiskCheckpoints(Builder builder) {
        if (!builder.budgetBytesSet) throw new IllegalArgumentException("budget_bytes is required");
        this.budgetBytes = Wire.nonNull(builder.budgetBytes, "budget_bytes");
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.checkpointsSet) throw new IllegalArgumentException("checkpoints is required");
        this.checkpoints = Wire.nonNull(builder.checkpoints, "checkpoints");
        if (!builder.largestBytesSet) throw new IllegalArgumentException("largest_bytes is required");
        this.largestBytes = Wire.nonNull(builder.largestBytes, "largest_bytes");
        if (!builder.overBudgetSet) throw new IllegalArgumentException("over_budget is required");
        this.overBudget = builder.overBudget;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 budgetBytes() { return budgetBytes; }
    public UInt64 bytes() { return bytes; }
    public UInt64 checkpoints() { return checkpoints; }
    public UInt64 largestBytes() { return largestBytes; }
    public boolean overBudget() { return overBudget; }

    public static ServerStatsDiskCheckpoints fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskCheckpoints");
        Builder builder = builder();
        Object rawBudgetBytes = Wire.required(object, "budget_bytes");
        builder.budgetBytes(Wire.uint64(rawBudgetBytes, "ServerStatsDiskCheckpoints.budget_bytes"));
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "ServerStatsDiskCheckpoints.bytes"));
        Object rawCheckpoints = Wire.required(object, "checkpoints");
        builder.checkpoints(Wire.uint64(rawCheckpoints, "ServerStatsDiskCheckpoints.checkpoints"));
        Object rawLargestBytes = Wire.required(object, "largest_bytes");
        builder.largestBytes(Wire.uint64(rawLargestBytes, "ServerStatsDiskCheckpoints.largest_bytes"));
        Object rawOverBudget = Wire.required(object, "over_budget");
        builder.overBudget(Wire.bool(rawOverBudget, "ServerStatsDiskCheckpoints.over_budget"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "budget_bytes", budgetBytes);
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "checkpoints", checkpoints);
        Wire.put(object, "largest_bytes", largestBytes);
        Wire.put(object, "over_budget", overBudget);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskCheckpoints that)) return false;
        return Objects.equals(budgetBytes, that.budgetBytes) && Objects.equals(bytes, that.bytes) && Objects.equals(checkpoints, that.checkpoints) && Objects.equals(largestBytes, that.largestBytes) && Objects.equals(overBudget, that.overBudget);
    }

    @Override
    public int hashCode() { return Objects.hash(budgetBytes, bytes, checkpoints, largestBytes, overBudget); }

    @Override
    public String toString() { return "ServerStatsDiskCheckpoints" + toWire(); }

    public static final class Builder {
        private UInt64 budgetBytes;
        private boolean budgetBytesSet;
        private UInt64 bytes;
        private boolean bytesSet;
        private UInt64 checkpoints;
        private boolean checkpointsSet;
        private UInt64 largestBytes;
        private boolean largestBytesSet;
        private Boolean overBudget;
        private boolean overBudgetSet;

        public Builder budgetBytes(UInt64 value) {
            this.budgetBytes = value;
            this.budgetBytesSet = true;
            return this;
        }
        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder checkpoints(UInt64 value) {
            this.checkpoints = value;
            this.checkpointsSet = true;
            return this;
        }
        public Builder largestBytes(UInt64 value) {
            this.largestBytes = value;
            this.largestBytesSet = true;
            return this;
        }
        public Builder overBudget(boolean value) {
            this.overBudget = value;
            this.overBudgetSet = true;
            return this;
        }
        public ServerStatsDiskCheckpoints build() { return new ServerStatsDiskCheckpoints(this); }
    }
}

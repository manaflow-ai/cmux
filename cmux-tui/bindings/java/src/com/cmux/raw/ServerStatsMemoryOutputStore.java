// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMemoryOutputStore implements WireValue {
    private final UInt64 capacityEstimateBytes;
    private final UInt64 logs;
    private final UInt64 pendingBytes;
    private final UInt64 tailBytes;

    private ServerStatsMemoryOutputStore(Builder builder) {
        if (!builder.capacityEstimateBytesSet) throw new IllegalArgumentException("capacity_estimate_bytes is required");
        this.capacityEstimateBytes = Wire.nonNull(builder.capacityEstimateBytes, "capacity_estimate_bytes");
        if (!builder.logsSet) throw new IllegalArgumentException("logs is required");
        this.logs = Wire.nonNull(builder.logs, "logs");
        if (!builder.pendingBytesSet) throw new IllegalArgumentException("pending_bytes is required");
        this.pendingBytes = Wire.nonNull(builder.pendingBytes, "pending_bytes");
        if (!builder.tailBytesSet) throw new IllegalArgumentException("tail_bytes is required");
        this.tailBytes = Wire.nonNull(builder.tailBytes, "tail_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 capacityEstimateBytes() { return capacityEstimateBytes; }
    public UInt64 logs() { return logs; }
    public UInt64 pendingBytes() { return pendingBytes; }
    public UInt64 tailBytes() { return tailBytes; }

    public static ServerStatsMemoryOutputStore fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMemoryOutputStore");
        Builder builder = builder();
        Object rawCapacityEstimateBytes = Wire.required(object, "capacity_estimate_bytes");
        builder.capacityEstimateBytes(Wire.uint64(rawCapacityEstimateBytes, "ServerStatsMemoryOutputStore.capacity_estimate_bytes"));
        Object rawLogs = Wire.required(object, "logs");
        builder.logs(Wire.uint64(rawLogs, "ServerStatsMemoryOutputStore.logs"));
        Object rawPendingBytes = Wire.required(object, "pending_bytes");
        builder.pendingBytes(Wire.uint64(rawPendingBytes, "ServerStatsMemoryOutputStore.pending_bytes"));
        Object rawTailBytes = Wire.required(object, "tail_bytes");
        builder.tailBytes(Wire.uint64(rawTailBytes, "ServerStatsMemoryOutputStore.tail_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "capacity_estimate_bytes", capacityEstimateBytes);
        Wire.put(object, "logs", logs);
        Wire.put(object, "pending_bytes", pendingBytes);
        Wire.put(object, "tail_bytes", tailBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMemoryOutputStore that)) return false;
        return Objects.equals(capacityEstimateBytes, that.capacityEstimateBytes) && Objects.equals(logs, that.logs) && Objects.equals(pendingBytes, that.pendingBytes) && Objects.equals(tailBytes, that.tailBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(capacityEstimateBytes, logs, pendingBytes, tailBytes); }

    @Override
    public String toString() { return "ServerStatsMemoryOutputStore" + toWire(); }

    public static final class Builder {
        private UInt64 capacityEstimateBytes;
        private boolean capacityEstimateBytesSet;
        private UInt64 logs;
        private boolean logsSet;
        private UInt64 pendingBytes;
        private boolean pendingBytesSet;
        private UInt64 tailBytes;
        private boolean tailBytesSet;

        public Builder capacityEstimateBytes(UInt64 value) {
            this.capacityEstimateBytes = value;
            this.capacityEstimateBytesSet = true;
            return this;
        }
        public Builder logs(UInt64 value) {
            this.logs = value;
            this.logsSet = true;
            return this;
        }
        public Builder pendingBytes(UInt64 value) {
            this.pendingBytes = value;
            this.pendingBytesSet = true;
            return this;
        }
        public Builder tailBytes(UInt64 value) {
            this.tailBytes = value;
            this.tailBytesSet = true;
            return this;
        }
        public ServerStatsMemoryOutputStore build() { return new ServerStatsMemoryOutputStore(this); }
    }
}

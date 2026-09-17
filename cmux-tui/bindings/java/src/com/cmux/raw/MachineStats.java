// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineStats implements WireValue {
    private final Double cpuPercent;
    private final long cpus;
    private final String diskPath;
    private final UInt64 diskTotalMb;
    private final UInt64 diskUsedMb;
    private final double loadAverage1m;
    private final UInt64 memoryTotalMb;
    private final UInt64 memoryUsedMb;
    private final UInt64 sampledAtMs;

    private MachineStats(Builder builder) {
        if (!builder.cpuPercentSet) throw new IllegalArgumentException("cpu_percent is required");
        this.cpuPercent = builder.cpuPercent;
        if (!builder.cpusSet) throw new IllegalArgumentException("cpus is required");
        this.cpus = builder.cpus;
        if (!builder.diskPathSet) throw new IllegalArgumentException("disk_path is required");
        this.diskPath = Wire.nonNull(builder.diskPath, "disk_path");
        if (!builder.diskTotalMbSet) throw new IllegalArgumentException("disk_total_mb is required");
        this.diskTotalMb = builder.diskTotalMb;
        if (!builder.diskUsedMbSet) throw new IllegalArgumentException("disk_used_mb is required");
        this.diskUsedMb = builder.diskUsedMb;
        if (!builder.loadAverage1mSet) throw new IllegalArgumentException("load_average_1m is required");
        this.loadAverage1m = builder.loadAverage1m;
        if (!builder.memoryTotalMbSet) throw new IllegalArgumentException("memory_total_mb is required");
        this.memoryTotalMb = Wire.nonNull(builder.memoryTotalMb, "memory_total_mb");
        if (!builder.memoryUsedMbSet) throw new IllegalArgumentException("memory_used_mb is required");
        this.memoryUsedMb = Wire.nonNull(builder.memoryUsedMb, "memory_used_mb");
        if (!builder.sampledAtMsSet) throw new IllegalArgumentException("sampled_at_ms is required");
        this.sampledAtMs = Wire.nonNull(builder.sampledAtMs, "sampled_at_ms");
    }

    public static Builder builder() { return new Builder(); }

    public Double cpuPercent() { return cpuPercent; }
    public long cpus() { return cpus; }
    public String diskPath() { return diskPath; }
    public UInt64 diskTotalMb() { return diskTotalMb; }
    public UInt64 diskUsedMb() { return diskUsedMb; }
    public double loadAverage1m() { return loadAverage1m; }
    public UInt64 memoryTotalMb() { return memoryTotalMb; }
    public UInt64 memoryUsedMb() { return memoryUsedMb; }
    public UInt64 sampledAtMs() { return sampledAtMs; }

    public static MachineStats fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineStats");
        Builder builder = builder();
        Object rawCpuPercent = Wire.required(object, "cpu_percent");
        builder.cpuPercent(rawCpuPercent == null ? null : Wire.float64(rawCpuPercent, "MachineStats.cpu_percent"));
        Object rawCpus = Wire.required(object, "cpus");
        builder.cpus(Wire.uint32(rawCpus, "MachineStats.cpus"));
        Object rawDiskPath = Wire.required(object, "disk_path");
        builder.diskPath(Wire.string(rawDiskPath, "MachineStats.disk_path"));
        Object rawDiskTotalMb = Wire.required(object, "disk_total_mb");
        builder.diskTotalMb(rawDiskTotalMb == null ? null : Wire.uint64(rawDiskTotalMb, "MachineStats.disk_total_mb"));
        Object rawDiskUsedMb = Wire.required(object, "disk_used_mb");
        builder.diskUsedMb(rawDiskUsedMb == null ? null : Wire.uint64(rawDiskUsedMb, "MachineStats.disk_used_mb"));
        Object rawLoadAverage1m = Wire.required(object, "load_average_1m");
        builder.loadAverage1m(Wire.float64(rawLoadAverage1m, "MachineStats.load_average_1m"));
        Object rawMemoryTotalMb = Wire.required(object, "memory_total_mb");
        builder.memoryTotalMb(Wire.uint64(rawMemoryTotalMb, "MachineStats.memory_total_mb"));
        Object rawMemoryUsedMb = Wire.required(object, "memory_used_mb");
        builder.memoryUsedMb(Wire.uint64(rawMemoryUsedMb, "MachineStats.memory_used_mb"));
        Object rawSampledAtMs = Wire.required(object, "sampled_at_ms");
        builder.sampledAtMs(Wire.uint64(rawSampledAtMs, "MachineStats.sampled_at_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cpu_percent", cpuPercent);
        Wire.put(object, "cpus", cpus);
        Wire.put(object, "disk_path", diskPath);
        Wire.put(object, "disk_total_mb", diskTotalMb);
        Wire.put(object, "disk_used_mb", diskUsedMb);
        Wire.put(object, "load_average_1m", loadAverage1m);
        Wire.put(object, "memory_total_mb", memoryTotalMb);
        Wire.put(object, "memory_used_mb", memoryUsedMb);
        Wire.put(object, "sampled_at_ms", sampledAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineStats that)) return false;
        return Objects.equals(cpuPercent, that.cpuPercent) && Objects.equals(cpus, that.cpus) && Objects.equals(diskPath, that.diskPath) && Objects.equals(diskTotalMb, that.diskTotalMb) && Objects.equals(diskUsedMb, that.diskUsedMb) && Objects.equals(loadAverage1m, that.loadAverage1m) && Objects.equals(memoryTotalMb, that.memoryTotalMb) && Objects.equals(memoryUsedMb, that.memoryUsedMb) && Objects.equals(sampledAtMs, that.sampledAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(cpuPercent, cpus, diskPath, diskTotalMb, diskUsedMb, loadAverage1m, memoryTotalMb, memoryUsedMb, sampledAtMs); }

    @Override
    public String toString() { return "MachineStats" + toWire(); }

    public static final class Builder {
        private Double cpuPercent;
        private boolean cpuPercentSet;
        private Long cpus;
        private boolean cpusSet;
        private String diskPath;
        private boolean diskPathSet;
        private UInt64 diskTotalMb;
        private boolean diskTotalMbSet;
        private UInt64 diskUsedMb;
        private boolean diskUsedMbSet;
        private Double loadAverage1m;
        private boolean loadAverage1mSet;
        private UInt64 memoryTotalMb;
        private boolean memoryTotalMbSet;
        private UInt64 memoryUsedMb;
        private boolean memoryUsedMbSet;
        private UInt64 sampledAtMs;
        private boolean sampledAtMsSet;

        public Builder cpuPercent(Double value) {
            this.cpuPercent = value;
            this.cpuPercentSet = true;
            return this;
        }
        public Builder cpus(long value) {
            this.cpus = value;
            this.cpusSet = true;
            return this;
        }
        public Builder diskPath(String value) {
            this.diskPath = value;
            this.diskPathSet = true;
            return this;
        }
        public Builder diskTotalMb(UInt64 value) {
            this.diskTotalMb = value;
            this.diskTotalMbSet = true;
            return this;
        }
        public Builder diskUsedMb(UInt64 value) {
            this.diskUsedMb = value;
            this.diskUsedMbSet = true;
            return this;
        }
        public Builder loadAverage1m(double value) {
            this.loadAverage1m = value;
            this.loadAverage1mSet = true;
            return this;
        }
        public Builder memoryTotalMb(UInt64 value) {
            this.memoryTotalMb = value;
            this.memoryTotalMbSet = true;
            return this;
        }
        public Builder memoryUsedMb(UInt64 value) {
            this.memoryUsedMb = value;
            this.memoryUsedMbSet = true;
            return this;
        }
        public Builder sampledAtMs(UInt64 value) {
            this.sampledAtMs = value;
            this.sampledAtMsSet = true;
            return this;
        }
        public MachineStats build() { return new MachineStats(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalResourceHost implements WireValue {
    private final UInt64 cpuNs;
    private final UInt64 memoryBytes;
    private final long pid;

    private TerminalResourceHost(Builder builder) {
        if (!builder.cpuNsSet) throw new IllegalArgumentException("cpu_ns is required");
        this.cpuNs = Wire.nonNull(builder.cpuNs, "cpu_ns");
        if (!builder.memoryBytesSet) throw new IllegalArgumentException("memory_bytes is required");
        this.memoryBytes = Wire.nonNull(builder.memoryBytes, "memory_bytes");
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 cpuNs() { return cpuNs; }
    public UInt64 memoryBytes() { return memoryBytes; }
    public long pid() { return pid; }

    public static TerminalResourceHost fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResourceHost");
        Builder builder = builder();
        Object rawCpuNs = Wire.required(object, "cpu_ns");
        builder.cpuNs(Wire.uint64(rawCpuNs, "TerminalResourceHost.cpu_ns"));
        Object rawMemoryBytes = Wire.required(object, "memory_bytes");
        builder.memoryBytes(Wire.uint64(rawMemoryBytes, "TerminalResourceHost.memory_bytes"));
        Object rawPid = Wire.required(object, "pid");
        builder.pid(Wire.uint32(rawPid, "TerminalResourceHost.pid"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cpu_ns", cpuNs);
        Wire.put(object, "memory_bytes", memoryBytes);
        Wire.put(object, "pid", pid);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalResourceHost that)) return false;
        return Objects.equals(cpuNs, that.cpuNs) && Objects.equals(memoryBytes, that.memoryBytes) && Objects.equals(pid, that.pid);
    }

    @Override
    public int hashCode() { return Objects.hash(cpuNs, memoryBytes, pid); }

    @Override
    public String toString() { return "TerminalResourceHost" + toWire(); }

    public static final class Builder {
        private UInt64 cpuNs;
        private boolean cpuNsSet;
        private UInt64 memoryBytes;
        private boolean memoryBytesSet;
        private Long pid;
        private boolean pidSet;

        public Builder cpuNs(UInt64 value) {
            this.cpuNs = value;
            this.cpuNsSet = true;
            return this;
        }
        public Builder memoryBytes(UInt64 value) {
            this.memoryBytes = value;
            this.memoryBytesSet = true;
            return this;
        }
        public Builder pid(long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public TerminalResourceHost build() { return new TerminalResourceHost(this); }
    }
}

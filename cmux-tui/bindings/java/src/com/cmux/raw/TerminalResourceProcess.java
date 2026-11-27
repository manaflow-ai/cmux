// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalResourceProcess implements WireValue {
    private final UInt64 cpuNs;
    private final UInt64 memoryBytes;
    private final String name;
    private final long pid;
    private final long ppid;

    private TerminalResourceProcess(Builder builder) {
        if (!builder.cpuNsSet) throw new IllegalArgumentException("cpu_ns is required");
        this.cpuNs = Wire.nonNull(builder.cpuNs, "cpu_ns");
        if (!builder.memoryBytesSet) throw new IllegalArgumentException("memory_bytes is required");
        this.memoryBytes = Wire.nonNull(builder.memoryBytes, "memory_bytes");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
        if (!builder.ppidSet) throw new IllegalArgumentException("ppid is required");
        this.ppid = builder.ppid;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 cpuNs() { return cpuNs; }
    public UInt64 memoryBytes() { return memoryBytes; }
    public String name() { return name; }
    public long pid() { return pid; }
    public long ppid() { return ppid; }

    public static TerminalResourceProcess fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResourceProcess");
        Builder builder = builder();
        Object rawCpuNs = Wire.required(object, "cpu_ns");
        builder.cpuNs(Wire.uint64(rawCpuNs, "TerminalResourceProcess.cpu_ns"));
        Object rawMemoryBytes = Wire.required(object, "memory_bytes");
        builder.memoryBytes(Wire.uint64(rawMemoryBytes, "TerminalResourceProcess.memory_bytes"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "TerminalResourceProcess.name"));
        Object rawPid = Wire.required(object, "pid");
        builder.pid(Wire.uint32(rawPid, "TerminalResourceProcess.pid"));
        Object rawPpid = Wire.required(object, "ppid");
        builder.ppid(Wire.uint32(rawPpid, "TerminalResourceProcess.ppid"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cpu_ns", cpuNs);
        Wire.put(object, "memory_bytes", memoryBytes);
        Wire.put(object, "name", name);
        Wire.put(object, "pid", pid);
        Wire.put(object, "ppid", ppid);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalResourceProcess that)) return false;
        return Objects.equals(cpuNs, that.cpuNs) && Objects.equals(memoryBytes, that.memoryBytes) && Objects.equals(name, that.name) && Objects.equals(pid, that.pid) && Objects.equals(ppid, that.ppid);
    }

    @Override
    public int hashCode() { return Objects.hash(cpuNs, memoryBytes, name, pid, ppid); }

    @Override
    public String toString() { return "TerminalResourceProcess" + toWire(); }

    public static final class Builder {
        private UInt64 cpuNs;
        private boolean cpuNsSet;
        private UInt64 memoryBytes;
        private boolean memoryBytesSet;
        private String name;
        private boolean nameSet;
        private Long pid;
        private boolean pidSet;
        private Long ppid;
        private boolean ppidSet;

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
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder pid(long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public Builder ppid(long value) {
            this.ppid = value;
            this.ppidSet = true;
            return this;
        }
        public TerminalResourceProcess build() { return new TerminalResourceProcess(this); }
    }
}

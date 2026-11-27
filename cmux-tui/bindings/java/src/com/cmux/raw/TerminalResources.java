// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalResources implements WireValue {
    private final TerminalResourceHost host;
    private final Long pid;
    private final List<TerminalResourceProcess> processes;
    private final UInt64 surface;
    private final String terminalId;
    private final boolean truncated;

    private TerminalResources(Builder builder) {
        if (!builder.hostSet) throw new IllegalArgumentException("host is required");
        this.host = builder.host;
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
        if (!builder.processesSet) throw new IllegalArgumentException("processes is required");
        this.processes = List.copyOf(Wire.nonNull(builder.processes, "processes"));
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = builder.terminalId;
        if (!builder.truncatedSet) throw new IllegalArgumentException("truncated is required");
        this.truncated = builder.truncated;
    }

    public static Builder builder() { return new Builder(); }

    public TerminalResourceHost host() { return host; }
    public Long pid() { return pid; }
    public List<TerminalResourceProcess> processes() { return processes; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public boolean truncated() { return truncated; }

    public static TerminalResources fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResources");
        Builder builder = builder();
        Object rawHost = Wire.required(object, "host");
        builder.host(rawHost == null ? null : TerminalResourceHost.fromWire(rawHost));
        Object rawPid = Wire.required(object, "pid");
        builder.pid(rawPid == null ? null : Wire.uint32(rawPid, "TerminalResources.pid"));
        Object rawProcesses = Wire.required(object, "processes");
        builder.processes(Wire.array(rawProcesses, "TerminalResources.processes", item -> TerminalResourceProcess.fromWire(item)));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalResources.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "TerminalResources.terminal_id"));
        Object rawTruncated = Wire.required(object, "truncated");
        builder.truncated(Wire.bool(rawTruncated, "TerminalResources.truncated"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "host", host);
        Wire.put(object, "pid", pid);
        Wire.put(object, "processes", processes);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "truncated", truncated);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalResources that)) return false;
        return Objects.equals(host, that.host) && Objects.equals(pid, that.pid) && Objects.equals(processes, that.processes) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(truncated, that.truncated);
    }

    @Override
    public int hashCode() { return Objects.hash(host, pid, processes, surface, terminalId, truncated); }

    @Override
    public String toString() { return "TerminalResources" + toWire(); }

    public static final class Builder {
        private TerminalResourceHost host;
        private boolean hostSet;
        private Long pid;
        private boolean pidSet;
        private List<TerminalResourceProcess> processes;
        private boolean processesSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;
        private Boolean truncated;
        private boolean truncatedSet;

        public Builder host(TerminalResourceHost value) {
            this.host = value;
            this.hostSet = true;
            return this;
        }
        public Builder pid(Long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public Builder processes(List<TerminalResourceProcess> value) {
            this.processes = value;
            this.processesSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder truncated(boolean value) {
            this.truncated = value;
            this.truncatedSet = true;
            return this;
        }
        public TerminalResources build() { return new TerminalResources(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentInventoryWatchActive implements WireValue {
    /** Canonical public machine id (`machine_…`) of the daemon that answered. */
    private final String machine;
    /** The owner's inventory revision when the lease became active. */
    private final UInt64 revision;
    /** Opaque lease id: `inventory_watch_` and 32 lowercase hex digits. */
    private final String watchId;

    private AgentInventoryWatchActive(Builder builder) {
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.watchIdSet) throw new IllegalArgumentException("watch_id is required");
        this.watchId = Wire.nonNull(builder.watchId, "watch_id");
    }

    public static Builder builder() { return new Builder(); }

    public String machine() { return machine; }
    public UInt64 revision() { return revision; }
    public String watchId() { return watchId; }

    public static AgentInventoryWatchActive fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryWatchActive");
        Builder builder = builder();
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentInventoryWatchActive.machine"));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "AgentInventoryWatchActive.revision"));
        Object rawWatchId = Wire.required(object, "watch_id");
        builder.watchId(Wire.string(rawWatchId, "AgentInventoryWatchActive.watch_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "machine", machine);
        Wire.put(object, "revision", revision);
        Wire.put(object, "watch_id", watchId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryWatchActive that)) return false;
        return Objects.equals(machine, that.machine) && Objects.equals(revision, that.revision) && Objects.equals(watchId, that.watchId);
    }

    @Override
    public int hashCode() { return Objects.hash(machine, revision, watchId); }

    @Override
    public String toString() { return "AgentInventoryWatchActive" + toWire(); }

    public static final class Builder {
        private String machine;
        private boolean machineSet;
        private UInt64 revision;
        private boolean revisionSet;
        private String watchId;
        private boolean watchIdSet;

        public Builder machine(String value) {
            this.machine = value;
            this.machineSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public Builder watchId(String value) {
            this.watchId = value;
            this.watchIdSet = true;
            return this;
        }
        public AgentInventoryWatchActive build() { return new AgentInventoryWatchActive(this); }
    }
}

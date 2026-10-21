// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-inventory-changed event. Protocol v12; streams: control. */
public final class AgentInventoryChangedEvent implements WireValue, ProtocolEvent {
    private final String machine;
    private final UInt64 revision;
    private final String watchId;

    private AgentInventoryChangedEvent(Builder builder) {
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
    @Override public String event() { return "agent-inventory-changed"; }

    public static AgentInventoryChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "agent-inventory-changed", "AgentInventoryChangedEvent.event");
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentInventoryChangedEvent.machine"));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "AgentInventoryChangedEvent.revision"));
        Object rawWatchId = Wire.required(object, "watch_id");
        builder.watchId(Wire.string(rawWatchId, "AgentInventoryChangedEvent.watch_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "agent-inventory-changed");
        Wire.put(object, "machine", machine);
        Wire.put(object, "revision", revision);
        Wire.put(object, "watch_id", watchId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryChangedEvent that)) return false;
        return Objects.equals(machine, that.machine) && Objects.equals(revision, that.revision) && Objects.equals(watchId, that.watchId);
    }

    @Override
    public int hashCode() { return Objects.hash(machine, revision, watchId); }

    @Override
    public String toString() { return "AgentInventoryChangedEvent" + toWire(); }

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
        public AgentInventoryChangedEvent build() { return new AgentInventoryChangedEvent(this); }
    }
}

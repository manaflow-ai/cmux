// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-inventory-watch-ended event. Protocol v12; streams: control. */
public final class AgentInventoryWatchEndedEvent implements WireValue, ProtocolEvent {
    private final String machine;
    private final String reason;
    private final String watchId;

    private AgentInventoryWatchEndedEvent(Builder builder) {
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
        if (!builder.watchIdSet) throw new IllegalArgumentException("watch_id is required");
        this.watchId = Wire.nonNull(builder.watchId, "watch_id");
    }

    public static Builder builder() { return new Builder(); }

    public String machine() { return machine; }
    public String reason() { return reason; }
    public String watchId() { return watchId; }
    @Override public String event() { return "agent-inventory-watch-ended"; }

    public static AgentInventoryWatchEndedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryWatchEndedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "agent-inventory-watch-ended", "AgentInventoryWatchEndedEvent.event");
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentInventoryWatchEndedEvent.machine"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(Wire.string(rawReason, "AgentInventoryWatchEndedEvent.reason"));
        Object rawWatchId = Wire.required(object, "watch_id");
        builder.watchId(Wire.string(rawWatchId, "AgentInventoryWatchEndedEvent.watch_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "agent-inventory-watch-ended");
        Wire.put(object, "machine", machine);
        Wire.put(object, "reason", reason);
        Wire.put(object, "watch_id", watchId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryWatchEndedEvent that)) return false;
        return Objects.equals(machine, that.machine) && Objects.equals(reason, that.reason) && Objects.equals(watchId, that.watchId);
    }

    @Override
    public int hashCode() { return Objects.hash(machine, reason, watchId); }

    @Override
    public String toString() { return "AgentInventoryWatchEndedEvent" + toWire(); }

    public static final class Builder {
        private String machine;
        private boolean machineSet;
        private String reason;
        private boolean reasonSet;
        private String watchId;
        private boolean watchIdSet;

        public Builder machine(String value) {
            this.machine = value;
            this.machineSet = true;
            return this;
        }
        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder watchId(String value) {
            this.watchId = value;
            this.watchIdSet = true;
            return this;
        }
        public AgentInventoryWatchEndedEvent build() { return new AgentInventoryWatchEndedEvent(this); }
    }
}

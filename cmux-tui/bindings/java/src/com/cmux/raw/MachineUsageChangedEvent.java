// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable machine-usage-changed event. Protocol v12; streams: subscribe. */
public final class MachineUsageChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final MachineUsage usage;

    private MachineUsageChangedEvent(Builder builder) {
        if (!builder.usageSet) throw new IllegalArgumentException("usage is required");
        this.usage = builder.usage;
    }

    public static Builder builder() { return new Builder(); }

    public MachineUsage usage() { return usage; }
    @Override public String event() { return "machine-usage-changed"; }

    public static MachineUsageChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineUsageChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "machine-usage-changed", "MachineUsageChangedEvent.event");
        Object rawUsage = Wire.required(object, "usage");
        builder.usage(rawUsage == null ? null : MachineUsage.fromWire(rawUsage));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "machine-usage-changed");
        Wire.put(object, "usage", usage);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineUsageChangedEvent that)) return false;
        return Objects.equals(usage, that.usage);
    }

    @Override
    public int hashCode() { return Objects.hash(usage); }

    @Override
    public String toString() { return "MachineUsageChangedEvent" + toWire(); }

    public static final class Builder {
        private MachineUsage usage;
        private boolean usageSet;

        public Builder usage(MachineUsage value) {
            this.usage = value;
            this.usageSet = true;
            return this;
        }
        public MachineUsageChangedEvent build() { return new MachineUsageChangedEvent(this); }
    }
}

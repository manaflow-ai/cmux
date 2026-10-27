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
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final MachineUsage usage;

    private MachineUsageChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.usageSet) throw new IllegalArgumentException("usage is required");
        this.usage = builder.usage;
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public MachineUsage usage() { return usage; }
    @Override public String event() { return "machine-usage-changed"; }

    public static MachineUsageChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineUsageChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "machine-usage-changed", "MachineUsageChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawUsage = Wire.required(object, "usage");
        builder.usage(rawUsage == null ? null : MachineUsage.fromWire(rawUsage));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "machine-usage-changed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "usage", usage);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineUsageChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(usage, that.usage);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, usage); }

    @Override
    public String toString() { return "MachineUsageChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private MachineUsage usage;
        private boolean usageSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder usage(MachineUsage value) {
            this.usage = value;
            this.usageSet = true;
            return this;
        }
        public MachineUsageChangedEvent build() { return new MachineUsageChangedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-cloud-machine event. Protocol v12; streams: control. */
public final class AppsCloudMachineEvent implements WireValue, ProtocolEvent {
    private final AppsCloudMachineEventKind kind;
    private final String machine;
    private final Field<Object> record_;

    private AppsCloudMachineEvent(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
        this.record_ = builder.record_.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public AppsCloudMachineEventKind kind() { return kind; }
    public String machine() { return machine; }
    public Field<Object> record_() { return record_; }
    @Override public String event() { return "apps-cloud-machine"; }

    public static AppsCloudMachineEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsCloudMachineEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "apps-cloud-machine", "AppsCloudMachineEvent.event");
        Object rawKind = Wire.required(object, "kind");
        builder.kind(AppsCloudMachineEventKind.fromWire(rawKind));
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AppsCloudMachineEvent.machine"));
        Object rawRecord = Wire.optional(object, "record");
        if (!Wire.isMissing(rawRecord)) {
            builder.record_(Wire.immutableJson(ProtocolSupport.nonNull(rawRecord, "AppsCloudMachineEvent.record")));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "apps-cloud-machine");
        Wire.put(object, "kind", kind);
        Wire.put(object, "machine", machine);
        Wire.put(object, "record", record_);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsCloudMachineEvent that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(machine, that.machine) && Objects.equals(record_, that.record_);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, machine, record_); }

    @Override
    public String toString() { return "AppsCloudMachineEvent" + toWire(); }

    public static final class Builder {
        private AppsCloudMachineEventKind kind;
        private boolean kindSet;
        private String machine;
        private boolean machineSet;
        private Field<Object> record_ = Field.omitted();

        public Builder kind(AppsCloudMachineEventKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder machine(String value) {
            this.machine = value;
            this.machineSet = true;
            return this;
        }
        public Builder record_(Object value) {
            this.record_ = Field.of(value);
            return this;
        }
        public AppsCloudMachineEvent build() { return new AppsCloudMachineEvent(this); }
    }
}

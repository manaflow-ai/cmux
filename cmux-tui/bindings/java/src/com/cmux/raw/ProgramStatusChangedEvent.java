// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable program-status-changed event. Protocol v12; streams: subscribe. */
public final class ProgramStatusChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final ShownProgramStatus programStatus;
    private final UInt64 surface;

    private ProgramStatusChangedEvent(Builder builder) {
        if (!builder.programStatusSet) throw new IllegalArgumentException("program_status is required");
        this.programStatus = builder.programStatus;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public ShownProgramStatus programStatus() { return programStatus; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "program-status-changed"; }

    public static ProgramStatusChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ProgramStatusChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "program-status-changed", "ProgramStatusChangedEvent.event");
        Object rawProgramStatus = Wire.required(object, "program_status");
        builder.programStatus(rawProgramStatus == null ? null : ShownProgramStatus.fromWire(rawProgramStatus));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ProgramStatusChangedEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "program-status-changed");
        Wire.put(object, "program_status", programStatus);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ProgramStatusChangedEvent that)) return false;
        return Objects.equals(programStatus, that.programStatus) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(programStatus, surface); }

    @Override
    public String toString() { return "ProgramStatusChangedEvent" + toWire(); }

    public static final class Builder {
        private ShownProgramStatus programStatus;
        private boolean programStatusSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder programStatus(ShownProgramStatus value) {
            this.programStatus = value;
            this.programStatusSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ProgramStatusChangedEvent build() { return new ProgramStatusChangedEvent(this); }
    }
}

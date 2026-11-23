// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-lean event. Protocol v12; streams: attach-byte. */
public final class AgentCliLeanEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final Bytes f;
    private final UInt64 surface;

    private AgentCliLeanEvent(Builder builder) {
        if (!builder.fSet) throw new IllegalArgumentException("f is required");
        this.f = Wire.nonNull(builder.f, "f");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Bytes f() { return f; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "agent-cli-lean"; }

    public static AgentCliLeanEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliLeanEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "agent-cli-lean", "AgentCliLeanEvent.event");
        Object rawF = Wire.required(object, "f");
        builder.f(Wire.bytes(rawF, "AgentCliLeanEvent.f"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentCliLeanEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "agent-cli-lean");
        Wire.put(object, "f", f);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliLeanEvent that)) return false;
        return Objects.equals(f, that.f) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(f, surface); }

    @Override
    public String toString() { return "AgentCliLeanEvent" + toWire(); }

    public static final class Builder {
        private Bytes f;
        private boolean fSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder f(Bytes value) {
            this.f = value;
            this.fSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentCliLeanEvent build() { return new AgentCliLeanEvent(this); }
    }
}

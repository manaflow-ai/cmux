// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable script-config-changed event. Protocol v12; streams: subscribe. */
public final class ScriptConfigChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 generation;

    private ScriptConfigChangedEvent(Builder builder) {
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 generation() { return generation; }
    @Override public String event() { return "script-config-changed"; }

    public static ScriptConfigChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptConfigChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "script-config-changed", "ScriptConfigChangedEvent.event");
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.uint64(rawGeneration, "ScriptConfigChangedEvent.generation"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "script-config-changed");
        Wire.put(object, "generation", generation);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptConfigChangedEvent that)) return false;
        return Objects.equals(generation, that.generation);
    }

    @Override
    public int hashCode() { return Objects.hash(generation); }

    @Override
    public String toString() { return "ScriptConfigChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 generation;
        private boolean generationSet;

        public Builder generation(UInt64 value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public ScriptConfigChangedEvent build() { return new ScriptConfigChangedEvent(this); }
    }
}

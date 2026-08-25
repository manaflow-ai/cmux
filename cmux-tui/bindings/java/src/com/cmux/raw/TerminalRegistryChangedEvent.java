// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-registry-changed event. Protocol v9; streams: subscribe. */
public final class TerminalRegistryChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String generation;
    private final String registryId;
    private final UInt64 terminalRevision;

    private TerminalRegistryChangedEvent(Builder builder) {
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
    }

    public static Builder builder() { return new Builder(); }

    public String generation() { return generation; }
    public String refetch() { return "terminal-events-or-list-terminals"; }
    public String registryId() { return registryId; }
    public UInt64 terminalRevision() { return terminalRevision; }
    @Override public String event() { return "terminal-registry-changed"; }

    public static TerminalRegistryChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalRegistryChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-registry-changed", "TerminalRegistryChangedEvent.event");
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "TerminalRegistryChangedEvent.generation"));
        Object rawRefetch = Wire.required(object, "refetch");
        ProtocolSupport.literal(rawRefetch, "terminal-events-or-list-terminals", "TerminalRegistryChangedEvent.refetch");
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "TerminalRegistryChangedEvent.registry_id"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "TerminalRegistryChangedEvent.terminal_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-registry-changed");
        Wire.put(object, "generation", generation);
        Wire.put(object, "refetch", "terminal-events-or-list-terminals");
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "terminal_revision", terminalRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalRegistryChangedEvent that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(registryId, that.registryId) && Objects.equals(terminalRevision, that.terminalRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, registryId, terminalRevision); }

    @Override
    public String toString() { return "TerminalRegistryChangedEvent" + toWire(); }

    public static final class Builder {
        private String generation;
        private boolean generationSet;
        private String registryId;
        private boolean registryIdSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;

        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = value;
            this.registryIdSet = true;
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = value;
            this.terminalRevisionSet = true;
            return this;
        }
        public TerminalRegistryChangedEvent build() { return new TerminalRegistryChangedEvent(this); }
    }
}

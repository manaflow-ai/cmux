// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalEventsResult implements WireValue {
    private final List<TerminalRegistryEvent> events;
    private final String generation;
    private final String registryId;
    private final UInt64 terminalRevision;

    private TerminalEventsResult(Builder builder) {
        if (!builder.eventsSet) throw new IllegalArgumentException("events is required");
        this.events = List.copyOf(Wire.nonNull(builder.events, "events"));
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
    }

    public static Builder builder() { return new Builder(); }

    public List<TerminalRegistryEvent> events() { return events; }
    public String generation() { return generation; }
    public String registryId() { return registryId; }
    public UInt64 terminalRevision() { return terminalRevision; }

    public static TerminalEventsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalEventsResult");
        Builder builder = builder();
        Object rawEvents = Wire.required(object, "events");
        builder.events(Wire.array(rawEvents, "TerminalEventsResult.events", item -> TerminalRegistryEvent.fromWire(item)));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "TerminalEventsResult.generation"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "TerminalEventsResult.registry_id"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "TerminalEventsResult.terminal_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "events", events);
        Wire.put(object, "generation", generation);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "terminal_revision", terminalRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalEventsResult that)) return false;
        return Objects.equals(events, that.events) && Objects.equals(generation, that.generation) && Objects.equals(registryId, that.registryId) && Objects.equals(terminalRevision, that.terminalRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(events, generation, registryId, terminalRevision); }

    @Override
    public String toString() { return "TerminalEventsResult" + toWire(); }

    public static final class Builder {
        private List<TerminalRegistryEvent> events;
        private boolean eventsSet;
        private String generation;
        private boolean generationSet;
        private String registryId;
        private boolean registryIdSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;

        public Builder events(List<TerminalRegistryEvent> value) {
            this.events = value;
            this.eventsSet = true;
            return this;
        }
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
        public TerminalEventsResult build() { return new TerminalEventsResult(this); }
    }
}

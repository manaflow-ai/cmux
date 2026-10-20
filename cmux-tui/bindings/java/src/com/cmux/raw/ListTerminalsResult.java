// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ListTerminalsResult implements WireValue {
    private final String generation;
    private final String registryId;
    private final UInt64 terminalRevision;
    private final List<TerminalRecord> terminals;

    private ListTerminalsResult(Builder builder) {
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
        if (!builder.terminalsSet) throw new IllegalArgumentException("terminals is required");
        this.terminals = List.copyOf(Wire.nonNull(builder.terminals, "terminals"));
    }

    public static Builder builder() { return new Builder(); }

    public String generation() { return generation; }
    public String registryId() { return registryId; }
    public UInt64 terminalRevision() { return terminalRevision; }
    public List<TerminalRecord> terminals() { return terminals; }

    public static ListTerminalsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListTerminalsResult");
        Builder builder = builder();
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "ListTerminalsResult.generation"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "ListTerminalsResult.registry_id"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "ListTerminalsResult.terminal_revision"));
        Object rawTerminals = Wire.required(object, "terminals");
        builder.terminals(Wire.array(rawTerminals, "ListTerminalsResult.terminals", item -> TerminalRecord.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "generation", generation);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "terminals", terminals);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListTerminalsResult that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(registryId, that.registryId) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(terminals, that.terminals);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, registryId, terminalRevision, terminals); }

    @Override
    public String toString() { return "ListTerminalsResult" + toWire(); }

    public static final class Builder {
        private String generation;
        private boolean generationSet;
        private String registryId;
        private boolean registryIdSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;
        private List<TerminalRecord> terminals;
        private boolean terminalsSet;

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
        public Builder terminals(List<TerminalRecord> value) {
            this.terminals = value;
            this.terminalsSet = true;
            return this;
        }
        public ListTerminalsResult build() { return new ListTerminalsResult(this); }
    }
}

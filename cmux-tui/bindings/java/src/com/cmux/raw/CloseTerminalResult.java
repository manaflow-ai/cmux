// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CloseTerminalResult implements WireValue {
    private final boolean alreadyClosed;
    private final String generation;
    private final String registryId;
    private final UInt64 surface;
    private final String terminalId;
    private final String terminalIncarnation;
    private final UInt64 terminalRevision;

    private CloseTerminalResult(Builder builder) {
        if (!builder.alreadyClosedSet) throw new IllegalArgumentException("already_closed is required");
        this.alreadyClosed = builder.alreadyClosed;
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = builder.surface;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.terminalIncarnationSet) throw new IllegalArgumentException("terminal_incarnation is required");
        this.terminalIncarnation = builder.terminalIncarnation;
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
    }

    public static Builder builder() { return new Builder(); }

    public boolean alreadyClosed() { return alreadyClosed; }
    public Boolean closed() { return true; }
    public String generation() { return generation; }
    public String registryId() { return registryId; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public String terminalIncarnation() { return terminalIncarnation; }
    public UInt64 terminalRevision() { return terminalRevision; }

    public static CloseTerminalResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseTerminalResult");
        Builder builder = builder();
        Object rawAlreadyClosed = Wire.required(object, "already_closed");
        builder.alreadyClosed(Wire.bool(rawAlreadyClosed, "CloseTerminalResult.already_closed"));
        Object rawClosed = Wire.required(object, "closed");
        ProtocolSupport.literal(rawClosed, true, "CloseTerminalResult.closed");
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "CloseTerminalResult.generation"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "CloseTerminalResult.registry_id"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "CloseTerminalResult.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "CloseTerminalResult.terminal_id"));
        Object rawTerminalIncarnation = Wire.required(object, "terminal_incarnation");
        builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "CloseTerminalResult.terminal_incarnation"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "CloseTerminalResult.terminal_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "already_closed", alreadyClosed);
        Wire.put(object, "closed", true);
        Wire.put(object, "generation", generation);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "terminal_revision", terminalRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseTerminalResult that)) return false;
        return Objects.equals(alreadyClosed, that.alreadyClosed) && Objects.equals(generation, that.generation) && Objects.equals(registryId, that.registryId) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(terminalRevision, that.terminalRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(alreadyClosed, generation, registryId, surface, terminalId, terminalIncarnation, terminalRevision); }

    @Override
    public String toString() { return "CloseTerminalResult" + toWire(); }

    public static final class Builder {
        private Boolean alreadyClosed;
        private boolean alreadyClosedSet;
        private String generation;
        private boolean generationSet;
        private String registryId;
        private boolean registryIdSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String terminalIncarnation;
        private boolean terminalIncarnationSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;

        public Builder alreadyClosed(boolean value) {
            this.alreadyClosed = value;
            this.alreadyClosedSet = true;
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
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = value;
            this.terminalIncarnationSet = true;
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = value;
            this.terminalRevisionSet = true;
            return this;
        }
        public CloseTerminalResult build() { return new CloseTerminalResult(this); }
    }
}

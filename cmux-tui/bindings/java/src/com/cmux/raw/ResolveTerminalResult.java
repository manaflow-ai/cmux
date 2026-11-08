// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ResolveTerminalResult implements WireValue {
    private final TerminalExit exit;
    private final String generation;
    private final Object launchSpec;
    private final TerminalLifecycle lifecycle;
    private final String registryId;
    private final UInt64 surface;
    private final String terminalId;
    private final String terminalIncarnation;
    private final UInt64 terminalRevision;
    private final String workspaceKey;

    private ResolveTerminalResult(Builder builder) {
        if (!builder.exitSet) throw new IllegalArgumentException("exit is required");
        this.exit = builder.exit;
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.launchSpecSet) throw new IllegalArgumentException("launch_spec is required");
        this.launchSpec = Wire.immutableJson(Wire.nonNull(builder.launchSpec, "launch_spec"));
        if (!builder.lifecycleSet) throw new IllegalArgumentException("lifecycle is required");
        this.lifecycle = Wire.nonNull(builder.lifecycle, "lifecycle");
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
        if (!builder.workspaceKeySet) throw new IllegalArgumentException("workspace_key is required");
        this.workspaceKey = Wire.nonNull(builder.workspaceKey, "workspace_key");
    }

    public static Builder builder() { return new Builder(); }

    public TerminalExit exit() { return exit; }
    public String generation() { return generation; }
    public Object launchSpec() { return launchSpec; }
    public TerminalLifecycle lifecycle() { return lifecycle; }
    public String registryId() { return registryId; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public String terminalIncarnation() { return terminalIncarnation; }
    public UInt64 terminalRevision() { return terminalRevision; }
    public String workspaceKey() { return workspaceKey; }

    public static ResolveTerminalResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResolveTerminalResult");
        Builder builder = builder();
        Object rawExit = Wire.required(object, "exit");
        builder.exit(rawExit == null ? null : TerminalExit.fromWire(rawExit));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "ResolveTerminalResult.generation"));
        Object rawLaunchSpec = Wire.required(object, "launch_spec");
        builder.launchSpec(Wire.immutableJson(rawLaunchSpec));
        Object rawLifecycle = Wire.required(object, "lifecycle");
        builder.lifecycle(TerminalLifecycle.fromWire(rawLifecycle));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "ResolveTerminalResult.registry_id"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "ResolveTerminalResult.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "ResolveTerminalResult.terminal_id"));
        Object rawTerminalIncarnation = Wire.required(object, "terminal_incarnation");
        builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "ResolveTerminalResult.terminal_incarnation"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "ResolveTerminalResult.terminal_revision"));
        Object rawWorkspaceKey = Wire.required(object, "workspace_key");
        builder.workspaceKey(Wire.string(rawWorkspaceKey, "ResolveTerminalResult.workspace_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "exit", exit);
        Wire.put(object, "generation", generation);
        Wire.put(object, "launch_spec", launchSpec);
        Wire.put(object, "lifecycle", lifecycle);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "workspace_key", workspaceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResolveTerminalResult that)) return false;
        return Objects.equals(exit, that.exit) && Objects.equals(generation, that.generation) && Objects.equals(launchSpec, that.launchSpec) && Objects.equals(lifecycle, that.lifecycle) && Objects.equals(registryId, that.registryId) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(workspaceKey, that.workspaceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(exit, generation, launchSpec, lifecycle, registryId, surface, terminalId, terminalIncarnation, terminalRevision, workspaceKey); }

    @Override
    public String toString() { return "ResolveTerminalResult" + toWire(); }

    public static final class Builder {
        private TerminalExit exit;
        private boolean exitSet;
        private String generation;
        private boolean generationSet;
        private Object launchSpec;
        private boolean launchSpecSet;
        private TerminalLifecycle lifecycle;
        private boolean lifecycleSet;
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
        private String workspaceKey;
        private boolean workspaceKeySet;

        public Builder exit(TerminalExit value) {
            this.exit = value;
            this.exitSet = true;
            return this;
        }
        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder launchSpec(Object value) {
            this.launchSpec = value;
            this.launchSpecSet = true;
            return this;
        }
        public Builder lifecycle(TerminalLifecycle value) {
            this.lifecycle = value;
            this.lifecycleSet = true;
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
        public Builder workspaceKey(String value) {
            this.workspaceKey = value;
            this.workspaceKeySet = true;
            return this;
        }
        public ResolveTerminalResult build() { return new ResolveTerminalResult(this); }
    }
}

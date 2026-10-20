// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalPlacement implements WireValue {
    private final boolean alreadyExited;
    private final TerminalExit exit;
    private final String generation;
    private final String key;
    private final TerminalLifecycle lifecycle;
    private final UInt64 pane;
    private final String registryId;
    private final boolean replayed;
    private final UInt64 screen;
    private final UInt64 surface;
    private final String terminalId;
    private final String terminalIncarnation;
    private final UInt64 terminalRevision;
    private final UInt64 workspace;

    private TerminalPlacement(Builder builder) {
        if (!builder.alreadyExitedSet) throw new IllegalArgumentException("already_exited is required");
        this.alreadyExited = builder.alreadyExited;
        if (!builder.exitSet) throw new IllegalArgumentException("exit is required");
        this.exit = builder.exit;
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.lifecycleSet) throw new IllegalArgumentException("lifecycle is required");
        this.lifecycle = Wire.nonNull(builder.lifecycle, "lifecycle");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = builder.screen;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = builder.surface;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.terminalIncarnationSet) throw new IllegalArgumentException("terminal_incarnation is required");
        this.terminalIncarnation = builder.terminalIncarnation;
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public boolean alreadyExited() { return alreadyExited; }
    public TerminalExit exit() { return exit; }
    public String generation() { return generation; }
    public String key() { return key; }
    public TerminalLifecycle lifecycle() { return lifecycle; }
    public UInt64 pane() { return pane; }
    public String registryId() { return registryId; }
    public boolean replayed() { return replayed; }
    public UInt64 screen() { return screen; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public String terminalIncarnation() { return terminalIncarnation; }
    public UInt64 terminalRevision() { return terminalRevision; }
    public UInt64 workspace() { return workspace; }

    public static TerminalPlacement fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalPlacement");
        Builder builder = builder();
        Object rawAlreadyExited = Wire.required(object, "already_exited");
        builder.alreadyExited(Wire.bool(rawAlreadyExited, "TerminalPlacement.already_exited"));
        Object rawExit = Wire.required(object, "exit");
        builder.exit(rawExit == null ? null : TerminalExit.fromWire(rawExit));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "TerminalPlacement.generation"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "TerminalPlacement.key"));
        Object rawLifecycle = Wire.required(object, "lifecycle");
        builder.lifecycle(TerminalLifecycle.fromWire(rawLifecycle));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "TerminalPlacement.pane"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "TerminalPlacement.registry_id"));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "TerminalPlacement.replayed"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(rawScreen == null ? null : Wire.uint64(rawScreen, "TerminalPlacement.screen"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "TerminalPlacement.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalPlacement.terminal_id"));
        Object rawTerminalIncarnation = Wire.required(object, "terminal_incarnation");
        builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "TerminalPlacement.terminal_incarnation"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "TerminalPlacement.terminal_revision"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "TerminalPlacement.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "already_exited", alreadyExited);
        Wire.put(object, "exit", exit);
        Wire.put(object, "generation", generation);
        Wire.put(object, "key", key);
        Wire.put(object, "lifecycle", lifecycle);
        Wire.put(object, "pane", pane);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "screen", screen);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalPlacement that)) return false;
        return Objects.equals(alreadyExited, that.alreadyExited) && Objects.equals(exit, that.exit) && Objects.equals(generation, that.generation) && Objects.equals(key, that.key) && Objects.equals(lifecycle, that.lifecycle) && Objects.equals(pane, that.pane) && Objects.equals(registryId, that.registryId) && Objects.equals(replayed, that.replayed) && Objects.equals(screen, that.screen) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(alreadyExited, exit, generation, key, lifecycle, pane, registryId, replayed, screen, surface, terminalId, terminalIncarnation, terminalRevision, workspace); }

    @Override
    public String toString() { return "TerminalPlacement" + toWire(); }

    public static final class Builder {
        private Boolean alreadyExited;
        private boolean alreadyExitedSet;
        private TerminalExit exit;
        private boolean exitSet;
        private String generation;
        private boolean generationSet;
        private String key;
        private boolean keySet;
        private TerminalLifecycle lifecycle;
        private boolean lifecycleSet;
        private UInt64 pane;
        private boolean paneSet;
        private String registryId;
        private boolean registryIdSet;
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 screen;
        private boolean screenSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String terminalIncarnation;
        private boolean terminalIncarnationSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder alreadyExited(boolean value) {
            this.alreadyExited = value;
            this.alreadyExitedSet = true;
            return this;
        }
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
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder lifecycle(TerminalLifecycle value) {
            this.lifecycle = value;
            this.lifecycleSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = value;
            this.registryIdSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
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
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public TerminalPlacement build() { return new TerminalPlacement(this); }
    }
}

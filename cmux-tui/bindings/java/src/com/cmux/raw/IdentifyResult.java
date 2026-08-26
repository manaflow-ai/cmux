// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class IdentifyResult implements WireValue {
    private final Field<String> buildCommit;
    private final Field<List<String>> capabilities;
    private final String generation;
    private final Field<String> ghosttyCommit;
    private final Field<Boolean> lifecycleReady;
    private final long pid;
    private final long protocol;
    private final String registryId;
    private final String session;
    private final UInt64 terminalRevision;
    private final String version;
    private final UInt64 workspaceRevision;

    private IdentifyResult(Builder builder) {
        this.buildCommit = builder.buildCommit;
        this.capabilities = builder.capabilities.map(value -> List.copyOf(value));
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        this.ghosttyCommit = builder.ghosttyCommit;
        this.lifecycleReady = builder.lifecycleReady;
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
        if (!builder.protocolSet) throw new IllegalArgumentException("protocol is required");
        this.protocol = builder.protocol;
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
        if (!builder.versionSet) throw new IllegalArgumentException("version is required");
        this.version = Wire.nonNull(builder.version, "version");
        if (!builder.workspaceRevisionSet) throw new IllegalArgumentException("workspace_revision is required");
        this.workspaceRevision = Wire.nonNull(builder.workspaceRevision, "workspace_revision");
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return "cmux-tui"; }
    public Field<String> buildCommit() { return buildCommit; }
    public Field<List<String>> capabilities() { return capabilities; }
    public Long daemonHandoff() { return 1L; }
    public String generation() { return generation; }
    public Field<String> ghosttyCommit() { return ghosttyCommit; }
    public Field<Boolean> lifecycleReady() { return lifecycleReady; }
    public long pid() { return pid; }
    public long protocol() { return protocol; }
    public String registryId() { return registryId; }
    public String session() { return session; }
    public UInt64 terminalRevision() { return terminalRevision; }
    public String version() { return version; }
    public UInt64 workspaceRevision() { return workspaceRevision; }

    public static IdentifyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdentifyResult");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        ProtocolSupport.literal(rawApp, "cmux-tui", "IdentifyResult.app");
        Object rawBuildCommit = Wire.optional(object, "build_commit");
        if (!Wire.isMissing(rawBuildCommit)) {
            builder.buildCommit(rawBuildCommit == null ? null : Wire.string(rawBuildCommit, "IdentifyResult.build_commit"));
        }
        Object rawCapabilities = Wire.optional(object, "capabilities");
        if (!Wire.isMissing(rawCapabilities)) {
            builder.capabilities(Wire.array(rawCapabilities, "IdentifyResult.capabilities", item -> Wire.string(item, "IdentifyResult.capabilities item")));
        }
        Object rawDaemonHandoff = Wire.required(object, "daemon_handoff");
        ProtocolSupport.literal(rawDaemonHandoff, 1L, "IdentifyResult.daemon_handoff");
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "IdentifyResult.generation"));
        Object rawGhosttyCommit = Wire.optional(object, "ghostty_commit");
        if (!Wire.isMissing(rawGhosttyCommit)) {
            builder.ghosttyCommit(rawGhosttyCommit == null ? null : Wire.string(rawGhosttyCommit, "IdentifyResult.ghostty_commit"));
        }
        Object rawLifecycleReady = Wire.optional(object, "lifecycle_ready");
        if (!Wire.isMissing(rawLifecycleReady)) {
            builder.lifecycleReady(Wire.bool(rawLifecycleReady, "IdentifyResult.lifecycle_ready"));
        }
        Object rawPid = Wire.required(object, "pid");
        builder.pid(Wire.uint32(rawPid, "IdentifyResult.pid"));
        Object rawProtocol = Wire.required(object, "protocol");
        builder.protocol(Wire.uint32(rawProtocol, "IdentifyResult.protocol"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "IdentifyResult.registry_id"));
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "IdentifyResult.session"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "IdentifyResult.terminal_revision"));
        Object rawVersion = Wire.required(object, "version");
        builder.version(Wire.string(rawVersion, "IdentifyResult.version"));
        Object rawWorkspaceRevision = Wire.required(object, "workspace_revision");
        builder.workspaceRevision(Wire.uint64(rawWorkspaceRevision, "IdentifyResult.workspace_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", "cmux-tui");
        Wire.put(object, "build_commit", buildCommit);
        Wire.put(object, "capabilities", capabilities);
        Wire.put(object, "daemon_handoff", 1L);
        Wire.put(object, "generation", generation);
        Wire.put(object, "ghostty_commit", ghosttyCommit);
        Wire.put(object, "lifecycle_ready", lifecycleReady);
        Wire.put(object, "pid", pid);
        Wire.put(object, "protocol", protocol);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "session", session);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "version", version);
        Wire.put(object, "workspace_revision", workspaceRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdentifyResult that)) return false;
        return Objects.equals(buildCommit, that.buildCommit) && Objects.equals(capabilities, that.capabilities) && Objects.equals(generation, that.generation) && Objects.equals(ghosttyCommit, that.ghosttyCommit) && Objects.equals(lifecycleReady, that.lifecycleReady) && Objects.equals(pid, that.pid) && Objects.equals(protocol, that.protocol) && Objects.equals(registryId, that.registryId) && Objects.equals(session, that.session) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(version, that.version) && Objects.equals(workspaceRevision, that.workspaceRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(buildCommit, capabilities, generation, ghosttyCommit, lifecycleReady, pid, protocol, registryId, session, terminalRevision, version, workspaceRevision); }

    @Override
    public String toString() { return "IdentifyResult" + toWire(); }

    public static final class Builder {
        private Field<String> buildCommit = Field.omitted();
        private Field<List<String>> capabilities = Field.omitted();
        private String generation;
        private boolean generationSet;
        private Field<String> ghosttyCommit = Field.omitted();
        private Field<Boolean> lifecycleReady = Field.omitted();
        private Long pid;
        private boolean pidSet;
        private Long protocol;
        private boolean protocolSet;
        private String registryId;
        private boolean registryIdSet;
        private String session;
        private boolean sessionSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;
        private String version;
        private boolean versionSet;
        private UInt64 workspaceRevision;
        private boolean workspaceRevisionSet;

        public Builder buildCommit(String value) {
            this.buildCommit = Field.ofNullable(value);
            return this;
        }
        public Builder capabilities(List<String> value) {
            this.capabilities = Field.of(value);
            return this;
        }
        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder ghosttyCommit(String value) {
            this.ghosttyCommit = Field.ofNullable(value);
            return this;
        }
        public Builder lifecycleReady(Boolean value) {
            this.lifecycleReady = Field.of(value);
            return this;
        }
        public Builder pid(long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public Builder protocol(long value) {
            this.protocol = value;
            this.protocolSet = true;
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = value;
            this.registryIdSet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = value;
            this.terminalRevisionSet = true;
            return this;
        }
        public Builder version(String value) {
            this.version = value;
            this.versionSet = true;
            return this;
        }
        public Builder workspaceRevision(UInt64 value) {
            this.workspaceRevision = value;
            this.workspaceRevisionSet = true;
            return this;
        }
        public IdentifyResult build() { return new IdentifyResult(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class IdentifyResult implements WireValue {
    private final Field<Long> apiRevision;
    private final Field<String> buildCommit;
    private final Field<String> buildId;
    private final Field<UInt64> buildTime;
    private final Field<Long> bulkFrameMax;
    private final Field<List<String>> capabilities;
    private final Field<String> cliPath;
    private final Field<String> crateVersion;
    private final Field<List<Integer>> framedMethods;
    private final String generation;
    private final Field<String> ghosttyCommit;
    private final Field<String> install;
    private final Field<String> launchSnapshotPath;
    private final Field<Boolean> lifecycleReady;
    private final Field<List<String>> machineCapabilities;
    private final Field<String> machineId;
    private final Field<String> machineName;
    private final Field<MachinePlatform> machinePlatform;
    private final Field<Long> minApiRevision;
    private final long pid;
    private final long protocol;
    private final String registryId;
    private final Field<String> sdkSchemaDigest;
    private final String session;
    private final Field<String> sessionId;
    private final Field<DaemonStartupMarks> startupMarks;
    private final UInt64 terminalRevision;
    private final Field<String> updateCommand;
    private final String version;
    private final UInt64 workspaceRevision;

    private IdentifyResult(Builder builder) {
        this.apiRevision = builder.apiRevision;
        this.buildCommit = builder.buildCommit;
        this.buildId = builder.buildId;
        this.buildTime = builder.buildTime;
        this.bulkFrameMax = builder.bulkFrameMax;
        this.capabilities = builder.capabilities.map(value -> List.copyOf(value));
        this.cliPath = builder.cliPath;
        this.crateVersion = builder.crateVersion;
        this.framedMethods = builder.framedMethods.map(value -> List.copyOf(value));
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        this.ghosttyCommit = builder.ghosttyCommit;
        this.install = builder.install;
        this.launchSnapshotPath = builder.launchSnapshotPath;
        this.lifecycleReady = builder.lifecycleReady;
        this.machineCapabilities = builder.machineCapabilities.map(value -> List.copyOf(value));
        this.machineId = builder.machineId;
        this.machineName = builder.machineName;
        this.machinePlatform = builder.machinePlatform;
        this.minApiRevision = builder.minApiRevision;
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
        if (!builder.protocolSet) throw new IllegalArgumentException("protocol is required");
        this.protocol = builder.protocol;
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        this.sdkSchemaDigest = builder.sdkSchemaDigest;
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
        this.sessionId = builder.sessionId;
        this.startupMarks = builder.startupMarks;
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
        this.updateCommand = builder.updateCommand;
        if (!builder.versionSet) throw new IllegalArgumentException("version is required");
        this.version = Wire.nonNull(builder.version, "version");
        if (!builder.workspaceRevisionSet) throw new IllegalArgumentException("workspace_revision is required");
        this.workspaceRevision = Wire.nonNull(builder.workspaceRevision, "workspace_revision");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Long> apiRevision() { return apiRevision; }
    public String app() { return "cmux-tui"; }
    public Field<String> buildCommit() { return buildCommit; }
    public Field<String> buildId() { return buildId; }
    public Field<UInt64> buildTime() { return buildTime; }
    public Field<Long> bulkFrameMax() { return bulkFrameMax; }
    public Field<List<String>> capabilities() { return capabilities; }
    public Field<String> cliPath() { return cliPath; }
    public Field<String> crateVersion() { return crateVersion; }
    public Long daemonHandoff() { return 1L; }
    public Field<List<Integer>> framedMethods() { return framedMethods; }
    public String generation() { return generation; }
    public Field<String> ghosttyCommit() { return ghosttyCommit; }
    public Field<String> install() { return install; }
    public Field<String> launchSnapshotPath() { return launchSnapshotPath; }
    public Field<Boolean> lifecycleReady() { return lifecycleReady; }
    public Field<List<String>> machineCapabilities() { return machineCapabilities; }
    public Field<String> machineId() { return machineId; }
    public Field<String> machineName() { return machineName; }
    public Field<MachinePlatform> machinePlatform() { return machinePlatform; }
    public Field<Long> minApiRevision() { return minApiRevision; }
    public long pid() { return pid; }
    public long protocol() { return protocol; }
    public String registryId() { return registryId; }
    public Field<String> sdkSchemaDigest() { return sdkSchemaDigest; }
    public String session() { return session; }
    public Field<String> sessionId() { return sessionId; }
    public Field<DaemonStartupMarks> startupMarks() { return startupMarks; }
    public UInt64 terminalRevision() { return terminalRevision; }
    public Field<String> updateCommand() { return updateCommand; }
    public String version() { return version; }
    public UInt64 workspaceRevision() { return workspaceRevision; }

    public static IdentifyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdentifyResult");
        Builder builder = builder();
        Object rawApiRevision = Wire.optional(object, "api_revision");
        if (!Wire.isMissing(rawApiRevision)) {
            builder.apiRevision(rawApiRevision == null ? null : Wire.uint32(rawApiRevision, "IdentifyResult.api_revision"));
        }
        Object rawApp = Wire.required(object, "app");
        ProtocolSupport.literal(rawApp, "cmux-tui", "IdentifyResult.app");
        Object rawBuildCommit = Wire.optional(object, "build_commit");
        if (!Wire.isMissing(rawBuildCommit)) {
            builder.buildCommit(rawBuildCommit == null ? null : Wire.string(rawBuildCommit, "IdentifyResult.build_commit"));
        }
        Object rawBuildId = Wire.optional(object, "build_id");
        if (!Wire.isMissing(rawBuildId)) {
            builder.buildId(rawBuildId == null ? null : Wire.string(rawBuildId, "IdentifyResult.build_id"));
        }
        Object rawBuildTime = Wire.optional(object, "build_time");
        if (!Wire.isMissing(rawBuildTime)) {
            builder.buildTime(rawBuildTime == null ? null : Wire.uint64(rawBuildTime, "IdentifyResult.build_time"));
        }
        Object rawBulkFrameMax = Wire.optional(object, "bulk_frame_max");
        if (!Wire.isMissing(rawBulkFrameMax)) {
            builder.bulkFrameMax(rawBulkFrameMax == null ? null : Wire.uint32(rawBulkFrameMax, "IdentifyResult.bulk_frame_max"));
        }
        Object rawCapabilities = Wire.optional(object, "capabilities");
        if (!Wire.isMissing(rawCapabilities)) {
            builder.capabilities(Wire.array(rawCapabilities, "IdentifyResult.capabilities", item -> Wire.string(item, "IdentifyResult.capabilities item")));
        }
        Object rawCliPath = Wire.optional(object, "cli_path");
        if (!Wire.isMissing(rawCliPath)) {
            builder.cliPath(rawCliPath == null ? null : Wire.string(rawCliPath, "IdentifyResult.cli_path"));
        }
        Object rawCrateVersion = Wire.optional(object, "crate_version");
        if (!Wire.isMissing(rawCrateVersion)) {
            builder.crateVersion(rawCrateVersion == null ? null : Wire.string(rawCrateVersion, "IdentifyResult.crate_version"));
        }
        Object rawDaemonHandoff = Wire.required(object, "daemon_handoff");
        ProtocolSupport.literal(rawDaemonHandoff, 1L, "IdentifyResult.daemon_handoff");
        Object rawFramedMethods = Wire.optional(object, "framed_methods");
        if (!Wire.isMissing(rawFramedMethods)) {
            builder.framedMethods(rawFramedMethods == null ? null : Wire.array(rawFramedMethods, "IdentifyResult.framed_methods", item -> Wire.uint16(item, "IdentifyResult.framed_methods item")));
        }
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "IdentifyResult.generation"));
        Object rawGhosttyCommit = Wire.optional(object, "ghostty_commit");
        if (!Wire.isMissing(rawGhosttyCommit)) {
            builder.ghosttyCommit(rawGhosttyCommit == null ? null : Wire.string(rawGhosttyCommit, "IdentifyResult.ghostty_commit"));
        }
        Object rawInstall = Wire.optional(object, "install");
        if (!Wire.isMissing(rawInstall)) {
            builder.install(rawInstall == null ? null : Wire.string(rawInstall, "IdentifyResult.install"));
        }
        Object rawLaunchSnapshotPath = Wire.optional(object, "launch_snapshot_path");
        if (!Wire.isMissing(rawLaunchSnapshotPath)) {
            builder.launchSnapshotPath(rawLaunchSnapshotPath == null ? null : Wire.string(rawLaunchSnapshotPath, "IdentifyResult.launch_snapshot_path"));
        }
        Object rawLifecycleReady = Wire.optional(object, "lifecycle_ready");
        if (!Wire.isMissing(rawLifecycleReady)) {
            builder.lifecycleReady(Wire.bool(rawLifecycleReady, "IdentifyResult.lifecycle_ready"));
        }
        Object rawMachineCapabilities = Wire.optional(object, "machine_capabilities");
        if (!Wire.isMissing(rawMachineCapabilities)) {
            builder.machineCapabilities(Wire.array(rawMachineCapabilities, "IdentifyResult.machine_capabilities", item -> Wire.string(item, "IdentifyResult.machine_capabilities item")));
        }
        Object rawMachineId = Wire.optional(object, "machine_id");
        if (!Wire.isMissing(rawMachineId)) {
            builder.machineId(Wire.string(rawMachineId, "IdentifyResult.machine_id"));
        }
        Object rawMachineName = Wire.optional(object, "machine_name");
        if (!Wire.isMissing(rawMachineName)) {
            builder.machineName(Wire.string(rawMachineName, "IdentifyResult.machine_name"));
        }
        Object rawMachinePlatform = Wire.optional(object, "machine_platform");
        if (!Wire.isMissing(rawMachinePlatform)) {
            builder.machinePlatform(MachinePlatform.fromWire(rawMachinePlatform));
        }
        Object rawMinApiRevision = Wire.optional(object, "min_api_revision");
        if (!Wire.isMissing(rawMinApiRevision)) {
            builder.minApiRevision(rawMinApiRevision == null ? null : Wire.uint32(rawMinApiRevision, "IdentifyResult.min_api_revision"));
        }
        Object rawPid = Wire.required(object, "pid");
        builder.pid(Wire.uint32(rawPid, "IdentifyResult.pid"));
        Object rawProtocol = Wire.required(object, "protocol");
        builder.protocol(Wire.uint32(rawProtocol, "IdentifyResult.protocol"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "IdentifyResult.registry_id"));
        Object rawSdkSchemaDigest = Wire.optional(object, "sdk_schema_digest");
        if (!Wire.isMissing(rawSdkSchemaDigest)) {
            builder.sdkSchemaDigest(rawSdkSchemaDigest == null ? null : Wire.string(rawSdkSchemaDigest, "IdentifyResult.sdk_schema_digest"));
        }
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "IdentifyResult.session"));
        Object rawSessionId = Wire.optional(object, "session_id");
        if (!Wire.isMissing(rawSessionId)) {
            builder.sessionId(Wire.string(rawSessionId, "IdentifyResult.session_id"));
        }
        Object rawStartupMarks = Wire.optional(object, "startup_marks");
        if (!Wire.isMissing(rawStartupMarks)) {
            builder.startupMarks(rawStartupMarks == null ? null : DaemonStartupMarks.fromWire(rawStartupMarks));
        }
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "IdentifyResult.terminal_revision"));
        Object rawUpdateCommand = Wire.optional(object, "update_command");
        if (!Wire.isMissing(rawUpdateCommand)) {
            builder.updateCommand(rawUpdateCommand == null ? null : Wire.string(rawUpdateCommand, "IdentifyResult.update_command"));
        }
        Object rawVersion = Wire.required(object, "version");
        builder.version(Wire.string(rawVersion, "IdentifyResult.version"));
        Object rawWorkspaceRevision = Wire.required(object, "workspace_revision");
        builder.workspaceRevision(Wire.uint64(rawWorkspaceRevision, "IdentifyResult.workspace_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "api_revision", apiRevision);
        Wire.put(object, "app", "cmux-tui");
        Wire.put(object, "build_commit", buildCommit);
        Wire.put(object, "build_id", buildId);
        Wire.put(object, "build_time", buildTime);
        Wire.put(object, "bulk_frame_max", bulkFrameMax);
        Wire.put(object, "capabilities", capabilities);
        Wire.put(object, "cli_path", cliPath);
        Wire.put(object, "crate_version", crateVersion);
        Wire.put(object, "daemon_handoff", 1L);
        Wire.put(object, "framed_methods", framedMethods);
        Wire.put(object, "generation", generation);
        Wire.put(object, "ghostty_commit", ghosttyCommit);
        Wire.put(object, "install", install);
        Wire.put(object, "launch_snapshot_path", launchSnapshotPath);
        Wire.put(object, "lifecycle_ready", lifecycleReady);
        Wire.put(object, "machine_capabilities", machineCapabilities);
        Wire.put(object, "machine_id", machineId);
        Wire.put(object, "machine_name", machineName);
        Wire.put(object, "machine_platform", machinePlatform);
        Wire.put(object, "min_api_revision", minApiRevision);
        Wire.put(object, "pid", pid);
        Wire.put(object, "protocol", protocol);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "sdk_schema_digest", sdkSchemaDigest);
        Wire.put(object, "session", session);
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "startup_marks", startupMarks);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "update_command", updateCommand);
        Wire.put(object, "version", version);
        Wire.put(object, "workspace_revision", workspaceRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdentifyResult that)) return false;
        return Objects.equals(apiRevision, that.apiRevision) && Objects.equals(buildCommit, that.buildCommit) && Objects.equals(buildId, that.buildId) && Objects.equals(buildTime, that.buildTime) && Objects.equals(bulkFrameMax, that.bulkFrameMax) && Objects.equals(capabilities, that.capabilities) && Objects.equals(cliPath, that.cliPath) && Objects.equals(crateVersion, that.crateVersion) && Objects.equals(framedMethods, that.framedMethods) && Objects.equals(generation, that.generation) && Objects.equals(ghosttyCommit, that.ghosttyCommit) && Objects.equals(install, that.install) && Objects.equals(launchSnapshotPath, that.launchSnapshotPath) && Objects.equals(lifecycleReady, that.lifecycleReady) && Objects.equals(machineCapabilities, that.machineCapabilities) && Objects.equals(machineId, that.machineId) && Objects.equals(machineName, that.machineName) && Objects.equals(machinePlatform, that.machinePlatform) && Objects.equals(minApiRevision, that.minApiRevision) && Objects.equals(pid, that.pid) && Objects.equals(protocol, that.protocol) && Objects.equals(registryId, that.registryId) && Objects.equals(sdkSchemaDigest, that.sdkSchemaDigest) && Objects.equals(session, that.session) && Objects.equals(sessionId, that.sessionId) && Objects.equals(startupMarks, that.startupMarks) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(updateCommand, that.updateCommand) && Objects.equals(version, that.version) && Objects.equals(workspaceRevision, that.workspaceRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(apiRevision, buildCommit, buildId, buildTime, bulkFrameMax, capabilities, cliPath, crateVersion, framedMethods, generation, ghosttyCommit, install, launchSnapshotPath, lifecycleReady, machineCapabilities, machineId, machineName, machinePlatform, minApiRevision, pid, protocol, registryId, sdkSchemaDigest, session, sessionId, startupMarks, terminalRevision, updateCommand, version, workspaceRevision); }

    @Override
    public String toString() { return "IdentifyResult" + toWire(); }

    public static final class Builder {
        private Field<Long> apiRevision = Field.omitted();
        private Field<String> buildCommit = Field.omitted();
        private Field<String> buildId = Field.omitted();
        private Field<UInt64> buildTime = Field.omitted();
        private Field<Long> bulkFrameMax = Field.omitted();
        private Field<List<String>> capabilities = Field.omitted();
        private Field<String> cliPath = Field.omitted();
        private Field<String> crateVersion = Field.omitted();
        private Field<List<Integer>> framedMethods = Field.omitted();
        private String generation;
        private boolean generationSet;
        private Field<String> ghosttyCommit = Field.omitted();
        private Field<String> install = Field.omitted();
        private Field<String> launchSnapshotPath = Field.omitted();
        private Field<Boolean> lifecycleReady = Field.omitted();
        private Field<List<String>> machineCapabilities = Field.omitted();
        private Field<String> machineId = Field.omitted();
        private Field<String> machineName = Field.omitted();
        private Field<MachinePlatform> machinePlatform = Field.omitted();
        private Field<Long> minApiRevision = Field.omitted();
        private Long pid;
        private boolean pidSet;
        private Long protocol;
        private boolean protocolSet;
        private String registryId;
        private boolean registryIdSet;
        private Field<String> sdkSchemaDigest = Field.omitted();
        private String session;
        private boolean sessionSet;
        private Field<String> sessionId = Field.omitted();
        private Field<DaemonStartupMarks> startupMarks = Field.omitted();
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;
        private Field<String> updateCommand = Field.omitted();
        private String version;
        private boolean versionSet;
        private UInt64 workspaceRevision;
        private boolean workspaceRevisionSet;

        public Builder apiRevision(Long value) {
            this.apiRevision = Field.ofNullable(value);
            return this;
        }
        public Builder buildCommit(String value) {
            this.buildCommit = Field.ofNullable(value);
            return this;
        }
        public Builder buildId(String value) {
            this.buildId = Field.ofNullable(value);
            return this;
        }
        public Builder buildTime(UInt64 value) {
            this.buildTime = Field.ofNullable(value);
            return this;
        }
        public Builder bulkFrameMax(Long value) {
            this.bulkFrameMax = Field.ofNullable(value);
            return this;
        }
        public Builder capabilities(List<String> value) {
            this.capabilities = Field.of(value);
            return this;
        }
        public Builder cliPath(String value) {
            this.cliPath = Field.ofNullable(value);
            return this;
        }
        public Builder crateVersion(String value) {
            this.crateVersion = Field.ofNullable(value);
            return this;
        }
        public Builder framedMethods(List<Integer> value) {
            this.framedMethods = Field.ofNullable(value);
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
        public Builder install(String value) {
            this.install = Field.ofNullable(value);
            return this;
        }
        public Builder launchSnapshotPath(String value) {
            this.launchSnapshotPath = Field.ofNullable(value);
            return this;
        }
        public Builder lifecycleReady(Boolean value) {
            this.lifecycleReady = Field.of(value);
            return this;
        }
        public Builder machineCapabilities(List<String> value) {
            this.machineCapabilities = Field.of(value);
            return this;
        }
        public Builder machineId(String value) {
            this.machineId = Field.of(value);
            return this;
        }
        public Builder machineName(String value) {
            this.machineName = Field.of(value);
            return this;
        }
        public Builder machinePlatform(MachinePlatform value) {
            this.machinePlatform = Field.of(value);
            return this;
        }
        public Builder minApiRevision(Long value) {
            this.minApiRevision = Field.ofNullable(value);
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
        public Builder sdkSchemaDigest(String value) {
            this.sdkSchemaDigest = Field.ofNullable(value);
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = Field.of(value);
            return this;
        }
        public Builder startupMarks(DaemonStartupMarks value) {
            this.startupMarks = Field.ofNullable(value);
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = value;
            this.terminalRevisionSet = true;
            return this;
        }
        public Builder updateCommand(String value) {
            this.updateCommand = Field.ofNullable(value);
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

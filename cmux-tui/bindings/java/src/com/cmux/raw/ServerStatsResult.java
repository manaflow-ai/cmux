// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsResult implements WireValue {
    private final ServerStatsConnections connections;
    private final Field<ServerStatsHistogram> dispatchQueueUs;
    private final Field<ServerStatsIpc> ipc;
    private final Field<List<ServerStatsMethodLatency>> ipcMethods;
    private final ServerStatsJournalWriter journalWriter;
    private final Field<ServerStatsLockClasses> lockClasses;
    private final ServerStatsRegistryLock registryLock;
    private final Field<ServerStatsRequestLatency> requestLatencyUs;
    private final Field<ServerStatsRequestPathIo> requestPathIo;
    private final Field<ServerStatsResourceProjection> resourceProjection;
    private final long schema;
    private final Field<ServerStatsSlowRequests> slowRequests;
    private final UInt64 uptimeMs;
    private final Field<ServerStatsWritePath> writePath;

    private ServerStatsResult(Builder builder) {
        if (!builder.connectionsSet) throw new IllegalArgumentException("connections is required");
        this.connections = Wire.nonNull(builder.connections, "connections");
        this.dispatchQueueUs = builder.dispatchQueueUs;
        this.ipc = builder.ipc;
        this.ipcMethods = builder.ipcMethods.map(value -> List.copyOf(value));
        if (!builder.journalWriterSet) throw new IllegalArgumentException("journal_writer is required");
        this.journalWriter = builder.journalWriter;
        this.lockClasses = builder.lockClasses;
        if (!builder.registryLockSet) throw new IllegalArgumentException("registry_lock is required");
        this.registryLock = Wire.nonNull(builder.registryLock, "registry_lock");
        this.requestLatencyUs = builder.requestLatencyUs;
        this.requestPathIo = builder.requestPathIo;
        this.resourceProjection = builder.resourceProjection;
        if (!builder.schemaSet) throw new IllegalArgumentException("schema is required");
        this.schema = builder.schema;
        this.slowRequests = builder.slowRequests;
        if (!builder.uptimeMsSet) throw new IllegalArgumentException("uptime_ms is required");
        this.uptimeMs = Wire.nonNull(builder.uptimeMs, "uptime_ms");
        this.writePath = builder.writePath;
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsConnections connections() { return connections; }
    public Field<ServerStatsHistogram> dispatchQueueUs() { return dispatchQueueUs; }
    public Field<ServerStatsIpc> ipc() { return ipc; }
    public Field<List<ServerStatsMethodLatency>> ipcMethods() { return ipcMethods; }
    public ServerStatsJournalWriter journalWriter() { return journalWriter; }
    public Field<ServerStatsLockClasses> lockClasses() { return lockClasses; }
    public ServerStatsRegistryLock registryLock() { return registryLock; }
    public Field<ServerStatsRequestLatency> requestLatencyUs() { return requestLatencyUs; }
    public Field<ServerStatsRequestPathIo> requestPathIo() { return requestPathIo; }
    public Field<ServerStatsResourceProjection> resourceProjection() { return resourceProjection; }
    public long schema() { return schema; }
    public Field<ServerStatsSlowRequests> slowRequests() { return slowRequests; }
    public UInt64 uptimeMs() { return uptimeMs; }
    public Field<ServerStatsWritePath> writePath() { return writePath; }

    public static ServerStatsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsResult");
        Builder builder = builder();
        Object rawConnections = Wire.required(object, "connections");
        builder.connections(ServerStatsConnections.fromWire(rawConnections));
        Object rawDispatchQueueUs = Wire.optional(object, "dispatch_queue_us");
        if (!Wire.isMissing(rawDispatchQueueUs)) {
            builder.dispatchQueueUs(ServerStatsHistogram.fromWire(rawDispatchQueueUs));
        }
        Object rawIpc = Wire.optional(object, "ipc");
        if (!Wire.isMissing(rawIpc)) {
            builder.ipc(ServerStatsIpc.fromWire(rawIpc));
        }
        Object rawIpcMethods = Wire.optional(object, "ipc_methods");
        if (!Wire.isMissing(rawIpcMethods)) {
            builder.ipcMethods(Wire.array(rawIpcMethods, "ServerStatsResult.ipc_methods", item -> ServerStatsMethodLatency.fromWire(item)));
        }
        Object rawJournalWriter = Wire.required(object, "journal_writer");
        builder.journalWriter(rawJournalWriter == null ? null : ServerStatsJournalWriter.fromWire(rawJournalWriter));
        Object rawLockClasses = Wire.optional(object, "lock_classes");
        if (!Wire.isMissing(rawLockClasses)) {
            builder.lockClasses(ServerStatsLockClasses.fromWire(rawLockClasses));
        }
        Object rawRegistryLock = Wire.required(object, "registry_lock");
        builder.registryLock(ServerStatsRegistryLock.fromWire(rawRegistryLock));
        Object rawRequestLatencyUs = Wire.optional(object, "request_latency_us");
        if (!Wire.isMissing(rawRequestLatencyUs)) {
            builder.requestLatencyUs(ServerStatsRequestLatency.fromWire(rawRequestLatencyUs));
        }
        Object rawRequestPathIo = Wire.optional(object, "request_path_io");
        if (!Wire.isMissing(rawRequestPathIo)) {
            builder.requestPathIo(ServerStatsRequestPathIo.fromWire(rawRequestPathIo));
        }
        Object rawResourceProjection = Wire.optional(object, "resource_projection");
        if (!Wire.isMissing(rawResourceProjection)) {
            builder.resourceProjection(ServerStatsResourceProjection.fromWire(rawResourceProjection));
        }
        Object rawSchema = Wire.required(object, "schema");
        builder.schema(Wire.uint32(rawSchema, "ServerStatsResult.schema"));
        Object rawSlowRequests = Wire.optional(object, "slow_requests");
        if (!Wire.isMissing(rawSlowRequests)) {
            builder.slowRequests(ServerStatsSlowRequests.fromWire(rawSlowRequests));
        }
        Object rawUptimeMs = Wire.required(object, "uptime_ms");
        builder.uptimeMs(Wire.uint64(rawUptimeMs, "ServerStatsResult.uptime_ms"));
        Object rawWritePath = Wire.optional(object, "write_path");
        if (!Wire.isMissing(rawWritePath)) {
            builder.writePath(ServerStatsWritePath.fromWire(rawWritePath));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "connections", connections);
        Wire.put(object, "dispatch_queue_us", dispatchQueueUs);
        Wire.put(object, "ipc", ipc);
        Wire.put(object, "ipc_methods", ipcMethods);
        Wire.put(object, "journal_writer", journalWriter);
        Wire.put(object, "lock_classes", lockClasses);
        Wire.put(object, "registry_lock", registryLock);
        Wire.put(object, "request_latency_us", requestLatencyUs);
        Wire.put(object, "request_path_io", requestPathIo);
        Wire.put(object, "resource_projection", resourceProjection);
        Wire.put(object, "schema", schema);
        Wire.put(object, "slow_requests", slowRequests);
        Wire.put(object, "uptime_ms", uptimeMs);
        Wire.put(object, "write_path", writePath);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsResult that)) return false;
        return Objects.equals(connections, that.connections) && Objects.equals(dispatchQueueUs, that.dispatchQueueUs) && Objects.equals(ipc, that.ipc) && Objects.equals(ipcMethods, that.ipcMethods) && Objects.equals(journalWriter, that.journalWriter) && Objects.equals(lockClasses, that.lockClasses) && Objects.equals(registryLock, that.registryLock) && Objects.equals(requestLatencyUs, that.requestLatencyUs) && Objects.equals(requestPathIo, that.requestPathIo) && Objects.equals(resourceProjection, that.resourceProjection) && Objects.equals(schema, that.schema) && Objects.equals(slowRequests, that.slowRequests) && Objects.equals(uptimeMs, that.uptimeMs) && Objects.equals(writePath, that.writePath);
    }

    @Override
    public int hashCode() { return Objects.hash(connections, dispatchQueueUs, ipc, ipcMethods, journalWriter, lockClasses, registryLock, requestLatencyUs, requestPathIo, resourceProjection, schema, slowRequests, uptimeMs, writePath); }

    @Override
    public String toString() { return "ServerStatsResult" + toWire(); }

    public static final class Builder {
        private ServerStatsConnections connections;
        private boolean connectionsSet;
        private Field<ServerStatsHistogram> dispatchQueueUs = Field.omitted();
        private Field<ServerStatsIpc> ipc = Field.omitted();
        private Field<List<ServerStatsMethodLatency>> ipcMethods = Field.omitted();
        private ServerStatsJournalWriter journalWriter;
        private boolean journalWriterSet;
        private Field<ServerStatsLockClasses> lockClasses = Field.omitted();
        private ServerStatsRegistryLock registryLock;
        private boolean registryLockSet;
        private Field<ServerStatsRequestLatency> requestLatencyUs = Field.omitted();
        private Field<ServerStatsRequestPathIo> requestPathIo = Field.omitted();
        private Field<ServerStatsResourceProjection> resourceProjection = Field.omitted();
        private Long schema;
        private boolean schemaSet;
        private Field<ServerStatsSlowRequests> slowRequests = Field.omitted();
        private UInt64 uptimeMs;
        private boolean uptimeMsSet;
        private Field<ServerStatsWritePath> writePath = Field.omitted();

        public Builder connections(ServerStatsConnections value) {
            this.connections = value;
            this.connectionsSet = true;
            return this;
        }
        public Builder dispatchQueueUs(ServerStatsHistogram value) {
            this.dispatchQueueUs = Field.of(value);
            return this;
        }
        public Builder ipc(ServerStatsIpc value) {
            this.ipc = Field.of(value);
            return this;
        }
        public Builder ipcMethods(List<ServerStatsMethodLatency> value) {
            this.ipcMethods = Field.of(value);
            return this;
        }
        public Builder journalWriter(ServerStatsJournalWriter value) {
            this.journalWriter = value;
            this.journalWriterSet = true;
            return this;
        }
        public Builder lockClasses(ServerStatsLockClasses value) {
            this.lockClasses = Field.of(value);
            return this;
        }
        public Builder registryLock(ServerStatsRegistryLock value) {
            this.registryLock = value;
            this.registryLockSet = true;
            return this;
        }
        public Builder requestLatencyUs(ServerStatsRequestLatency value) {
            this.requestLatencyUs = Field.of(value);
            return this;
        }
        public Builder requestPathIo(ServerStatsRequestPathIo value) {
            this.requestPathIo = Field.of(value);
            return this;
        }
        public Builder resourceProjection(ServerStatsResourceProjection value) {
            this.resourceProjection = Field.of(value);
            return this;
        }
        public Builder schema(long value) {
            this.schema = value;
            this.schemaSet = true;
            return this;
        }
        public Builder slowRequests(ServerStatsSlowRequests value) {
            this.slowRequests = Field.of(value);
            return this;
        }
        public Builder uptimeMs(UInt64 value) {
            this.uptimeMs = value;
            this.uptimeMsSet = true;
            return this;
        }
        public Builder writePath(ServerStatsWritePath value) {
            this.writePath = Field.of(value);
            return this;
        }
        public ServerStatsResult build() { return new ServerStatsResult(this); }
    }
}

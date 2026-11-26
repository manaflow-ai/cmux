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
    private final ServerStatsJournalWriter journalWriter;
    private final ServerStatsRegistryLock registryLock;
    private final long schema;
    private final UInt64 uptimeMs;

    private ServerStatsResult(Builder builder) {
        if (!builder.connectionsSet) throw new IllegalArgumentException("connections is required");
        this.connections = Wire.nonNull(builder.connections, "connections");
        if (!builder.journalWriterSet) throw new IllegalArgumentException("journal_writer is required");
        this.journalWriter = builder.journalWriter;
        if (!builder.registryLockSet) throw new IllegalArgumentException("registry_lock is required");
        this.registryLock = Wire.nonNull(builder.registryLock, "registry_lock");
        if (!builder.schemaSet) throw new IllegalArgumentException("schema is required");
        this.schema = builder.schema;
        if (!builder.uptimeMsSet) throw new IllegalArgumentException("uptime_ms is required");
        this.uptimeMs = Wire.nonNull(builder.uptimeMs, "uptime_ms");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsConnections connections() { return connections; }
    public ServerStatsJournalWriter journalWriter() { return journalWriter; }
    public ServerStatsRegistryLock registryLock() { return registryLock; }
    public long schema() { return schema; }
    public UInt64 uptimeMs() { return uptimeMs; }

    public static ServerStatsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsResult");
        Builder builder = builder();
        Object rawConnections = Wire.required(object, "connections");
        builder.connections(ServerStatsConnections.fromWire(rawConnections));
        Object rawJournalWriter = Wire.required(object, "journal_writer");
        builder.journalWriter(rawJournalWriter == null ? null : ServerStatsJournalWriter.fromWire(rawJournalWriter));
        Object rawRegistryLock = Wire.required(object, "registry_lock");
        builder.registryLock(ServerStatsRegistryLock.fromWire(rawRegistryLock));
        Object rawSchema = Wire.required(object, "schema");
        builder.schema(Wire.uint32(rawSchema, "ServerStatsResult.schema"));
        Object rawUptimeMs = Wire.required(object, "uptime_ms");
        builder.uptimeMs(Wire.uint64(rawUptimeMs, "ServerStatsResult.uptime_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "connections", connections);
        Wire.put(object, "journal_writer", journalWriter);
        Wire.put(object, "registry_lock", registryLock);
        Wire.put(object, "schema", schema);
        Wire.put(object, "uptime_ms", uptimeMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsResult that)) return false;
        return Objects.equals(connections, that.connections) && Objects.equals(journalWriter, that.journalWriter) && Objects.equals(registryLock, that.registryLock) && Objects.equals(schema, that.schema) && Objects.equals(uptimeMs, that.uptimeMs);
    }

    @Override
    public int hashCode() { return Objects.hash(connections, journalWriter, registryLock, schema, uptimeMs); }

    @Override
    public String toString() { return "ServerStatsResult" + toWire(); }

    public static final class Builder {
        private ServerStatsConnections connections;
        private boolean connectionsSet;
        private ServerStatsJournalWriter journalWriter;
        private boolean journalWriterSet;
        private ServerStatsRegistryLock registryLock;
        private boolean registryLockSet;
        private Long schema;
        private boolean schemaSet;
        private UInt64 uptimeMs;
        private boolean uptimeMsSet;

        public Builder connections(ServerStatsConnections value) {
            this.connections = value;
            this.connectionsSet = true;
            return this;
        }
        public Builder journalWriter(ServerStatsJournalWriter value) {
            this.journalWriter = value;
            this.journalWriterSet = true;
            return this;
        }
        public Builder registryLock(ServerStatsRegistryLock value) {
            this.registryLock = value;
            this.registryLockSet = true;
            return this;
        }
        public Builder schema(long value) {
            this.schema = value;
            this.schemaSet = true;
            return this;
        }
        public Builder uptimeMs(UInt64 value) {
            this.uptimeMs = value;
            this.uptimeMsSet = true;
            return this;
        }
        public ServerStatsResult build() { return new ServerStatsResult(this); }
    }
}

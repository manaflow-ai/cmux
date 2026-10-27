// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRequestPathIo implements WireValue {
    private final UInt64 childProcess;
    private final UInt64 fsWrite;
    private final UInt64 hostWait;
    private final UInt64 journalWait;
    private final Field<UInt64> lockHoldOver1ms;
    private final Field<ServerStatsLockWaits> lockWaits;
    private final UInt64 network;
    private final UInt64 procScan;
    private final UInt64 processSpawn;
    private final boolean recording;
    private final UInt64 scopes;
    private final List<ServerStatsRequestPathSite> sites;
    private final UInt64 sleep;
    private final UInt64 sqlite;

    private ServerStatsRequestPathIo(Builder builder) {
        if (!builder.childProcessSet) throw new IllegalArgumentException("child_process is required");
        this.childProcess = Wire.nonNull(builder.childProcess, "child_process");
        if (!builder.fsWriteSet) throw new IllegalArgumentException("fs_write is required");
        this.fsWrite = Wire.nonNull(builder.fsWrite, "fs_write");
        if (!builder.hostWaitSet) throw new IllegalArgumentException("host_wait is required");
        this.hostWait = Wire.nonNull(builder.hostWait, "host_wait");
        if (!builder.journalWaitSet) throw new IllegalArgumentException("journal_wait is required");
        this.journalWait = Wire.nonNull(builder.journalWait, "journal_wait");
        this.lockHoldOver1ms = builder.lockHoldOver1ms;
        this.lockWaits = builder.lockWaits;
        if (!builder.networkSet) throw new IllegalArgumentException("network is required");
        this.network = Wire.nonNull(builder.network, "network");
        if (!builder.procScanSet) throw new IllegalArgumentException("proc_scan is required");
        this.procScan = Wire.nonNull(builder.procScan, "proc_scan");
        if (!builder.processSpawnSet) throw new IllegalArgumentException("process_spawn is required");
        this.processSpawn = Wire.nonNull(builder.processSpawn, "process_spawn");
        if (!builder.recordingSet) throw new IllegalArgumentException("recording is required");
        this.recording = builder.recording;
        if (!builder.scopesSet) throw new IllegalArgumentException("scopes is required");
        this.scopes = Wire.nonNull(builder.scopes, "scopes");
        if (!builder.sitesSet) throw new IllegalArgumentException("sites is required");
        this.sites = List.copyOf(Wire.nonNull(builder.sites, "sites"));
        if (!builder.sleepSet) throw new IllegalArgumentException("sleep is required");
        this.sleep = Wire.nonNull(builder.sleep, "sleep");
        if (!builder.sqliteSet) throw new IllegalArgumentException("sqlite is required");
        this.sqlite = Wire.nonNull(builder.sqlite, "sqlite");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 childProcess() { return childProcess; }
    public UInt64 fsWrite() { return fsWrite; }
    public UInt64 hostWait() { return hostWait; }
    public UInt64 journalWait() { return journalWait; }
    public Field<UInt64> lockHoldOver1ms() { return lockHoldOver1ms; }
    public Field<ServerStatsLockWaits> lockWaits() { return lockWaits; }
    public UInt64 network() { return network; }
    public UInt64 procScan() { return procScan; }
    public UInt64 processSpawn() { return processSpawn; }
    public boolean recording() { return recording; }
    public UInt64 scopes() { return scopes; }
    public List<ServerStatsRequestPathSite> sites() { return sites; }
    public UInt64 sleep() { return sleep; }
    public UInt64 sqlite() { return sqlite; }

    public static ServerStatsRequestPathIo fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRequestPathIo");
        Builder builder = builder();
        Object rawChildProcess = Wire.required(object, "child_process");
        builder.childProcess(Wire.uint64(rawChildProcess, "ServerStatsRequestPathIo.child_process"));
        Object rawFsWrite = Wire.required(object, "fs_write");
        builder.fsWrite(Wire.uint64(rawFsWrite, "ServerStatsRequestPathIo.fs_write"));
        Object rawHostWait = Wire.required(object, "host_wait");
        builder.hostWait(Wire.uint64(rawHostWait, "ServerStatsRequestPathIo.host_wait"));
        Object rawJournalWait = Wire.required(object, "journal_wait");
        builder.journalWait(Wire.uint64(rawJournalWait, "ServerStatsRequestPathIo.journal_wait"));
        Object rawLockHoldOver1ms = Wire.optional(object, "lock_hold_over_1ms");
        if (!Wire.isMissing(rawLockHoldOver1ms)) {
            builder.lockHoldOver1ms(Wire.uint64(rawLockHoldOver1ms, "ServerStatsRequestPathIo.lock_hold_over_1ms"));
        }
        Object rawLockWaits = Wire.optional(object, "lock_waits");
        if (!Wire.isMissing(rawLockWaits)) {
            builder.lockWaits(ServerStatsLockWaits.fromWire(rawLockWaits));
        }
        Object rawNetwork = Wire.required(object, "network");
        builder.network(Wire.uint64(rawNetwork, "ServerStatsRequestPathIo.network"));
        Object rawProcScan = Wire.required(object, "proc_scan");
        builder.procScan(Wire.uint64(rawProcScan, "ServerStatsRequestPathIo.proc_scan"));
        Object rawProcessSpawn = Wire.required(object, "process_spawn");
        builder.processSpawn(Wire.uint64(rawProcessSpawn, "ServerStatsRequestPathIo.process_spawn"));
        Object rawRecording = Wire.required(object, "recording");
        builder.recording(Wire.bool(rawRecording, "ServerStatsRequestPathIo.recording"));
        Object rawScopes = Wire.required(object, "scopes");
        builder.scopes(Wire.uint64(rawScopes, "ServerStatsRequestPathIo.scopes"));
        Object rawSites = Wire.required(object, "sites");
        builder.sites(Wire.array(rawSites, "ServerStatsRequestPathIo.sites", item -> ServerStatsRequestPathSite.fromWire(item)));
        Object rawSleep = Wire.required(object, "sleep");
        builder.sleep(Wire.uint64(rawSleep, "ServerStatsRequestPathIo.sleep"));
        Object rawSqlite = Wire.required(object, "sqlite");
        builder.sqlite(Wire.uint64(rawSqlite, "ServerStatsRequestPathIo.sqlite"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "child_process", childProcess);
        Wire.put(object, "fs_write", fsWrite);
        Wire.put(object, "host_wait", hostWait);
        Wire.put(object, "journal_wait", journalWait);
        Wire.put(object, "lock_hold_over_1ms", lockHoldOver1ms);
        Wire.put(object, "lock_waits", lockWaits);
        Wire.put(object, "network", network);
        Wire.put(object, "proc_scan", procScan);
        Wire.put(object, "process_spawn", processSpawn);
        Wire.put(object, "recording", recording);
        Wire.put(object, "scopes", scopes);
        Wire.put(object, "sites", sites);
        Wire.put(object, "sleep", sleep);
        Wire.put(object, "sqlite", sqlite);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRequestPathIo that)) return false;
        return Objects.equals(childProcess, that.childProcess) && Objects.equals(fsWrite, that.fsWrite) && Objects.equals(hostWait, that.hostWait) && Objects.equals(journalWait, that.journalWait) && Objects.equals(lockHoldOver1ms, that.lockHoldOver1ms) && Objects.equals(lockWaits, that.lockWaits) && Objects.equals(network, that.network) && Objects.equals(procScan, that.procScan) && Objects.equals(processSpawn, that.processSpawn) && Objects.equals(recording, that.recording) && Objects.equals(scopes, that.scopes) && Objects.equals(sites, that.sites) && Objects.equals(sleep, that.sleep) && Objects.equals(sqlite, that.sqlite);
    }

    @Override
    public int hashCode() { return Objects.hash(childProcess, fsWrite, hostWait, journalWait, lockHoldOver1ms, lockWaits, network, procScan, processSpawn, recording, scopes, sites, sleep, sqlite); }

    @Override
    public String toString() { return "ServerStatsRequestPathIo" + toWire(); }

    public static final class Builder {
        private UInt64 childProcess;
        private boolean childProcessSet;
        private UInt64 fsWrite;
        private boolean fsWriteSet;
        private UInt64 hostWait;
        private boolean hostWaitSet;
        private UInt64 journalWait;
        private boolean journalWaitSet;
        private Field<UInt64> lockHoldOver1ms = Field.omitted();
        private Field<ServerStatsLockWaits> lockWaits = Field.omitted();
        private UInt64 network;
        private boolean networkSet;
        private UInt64 procScan;
        private boolean procScanSet;
        private UInt64 processSpawn;
        private boolean processSpawnSet;
        private Boolean recording;
        private boolean recordingSet;
        private UInt64 scopes;
        private boolean scopesSet;
        private List<ServerStatsRequestPathSite> sites;
        private boolean sitesSet;
        private UInt64 sleep;
        private boolean sleepSet;
        private UInt64 sqlite;
        private boolean sqliteSet;

        public Builder childProcess(UInt64 value) {
            this.childProcess = value;
            this.childProcessSet = true;
            return this;
        }
        public Builder fsWrite(UInt64 value) {
            this.fsWrite = value;
            this.fsWriteSet = true;
            return this;
        }
        public Builder hostWait(UInt64 value) {
            this.hostWait = value;
            this.hostWaitSet = true;
            return this;
        }
        public Builder journalWait(UInt64 value) {
            this.journalWait = value;
            this.journalWaitSet = true;
            return this;
        }
        public Builder lockHoldOver1ms(UInt64 value) {
            this.lockHoldOver1ms = Field.of(value);
            return this;
        }
        public Builder lockWaits(ServerStatsLockWaits value) {
            this.lockWaits = Field.of(value);
            return this;
        }
        public Builder network(UInt64 value) {
            this.network = value;
            this.networkSet = true;
            return this;
        }
        public Builder procScan(UInt64 value) {
            this.procScan = value;
            this.procScanSet = true;
            return this;
        }
        public Builder processSpawn(UInt64 value) {
            this.processSpawn = value;
            this.processSpawnSet = true;
            return this;
        }
        public Builder recording(boolean value) {
            this.recording = value;
            this.recordingSet = true;
            return this;
        }
        public Builder scopes(UInt64 value) {
            this.scopes = value;
            this.scopesSet = true;
            return this;
        }
        public Builder sites(List<ServerStatsRequestPathSite> value) {
            this.sites = value;
            this.sitesSet = true;
            return this;
        }
        public Builder sleep(UInt64 value) {
            this.sleep = value;
            this.sleepSet = true;
            return this;
        }
        public Builder sqlite(UInt64 value) {
            this.sqlite = value;
            this.sqliteSet = true;
            return this;
        }
        public ServerStatsRequestPathIo build() { return new ServerStatsRequestPathIo(this); }
    }
}

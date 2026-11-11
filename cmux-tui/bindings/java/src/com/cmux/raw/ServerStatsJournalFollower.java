// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsJournalFollower implements WireValue {
    private final UInt64 client;
    private final UInt64 connectedMs;
    private final boolean keepsHookRows;
    private final boolean keepsReportRows;
    private final List<String> kinds;
    private final UInt64 leftMs;
    private final String maxSensitivity;
    private final boolean remote;
    private final String streamId;

    private ServerStatsJournalFollower(Builder builder) {
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        if (!builder.connectedMsSet) throw new IllegalArgumentException("connected_ms is required");
        this.connectedMs = Wire.nonNull(builder.connectedMs, "connected_ms");
        if (!builder.keepsHookRowsSet) throw new IllegalArgumentException("keeps_hook_rows is required");
        this.keepsHookRows = builder.keepsHookRows;
        if (!builder.keepsReportRowsSet) throw new IllegalArgumentException("keeps_report_rows is required");
        this.keepsReportRows = builder.keepsReportRows;
        if (!builder.kindsSet) throw new IllegalArgumentException("kinds is required");
        this.kinds = List.copyOf(Wire.nonNull(builder.kinds, "kinds"));
        if (!builder.leftMsSet) throw new IllegalArgumentException("left_ms is required");
        this.leftMs = builder.leftMs;
        if (!builder.maxSensitivitySet) throw new IllegalArgumentException("max_sensitivity is required");
        this.maxSensitivity = builder.maxSensitivity;
        if (!builder.remoteSet) throw new IllegalArgumentException("remote is required");
        this.remote = builder.remote;
        if (!builder.streamIdSet) throw new IllegalArgumentException("stream_id is required");
        this.streamId = Wire.nonNull(builder.streamId, "stream_id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 client() { return client; }
    public UInt64 connectedMs() { return connectedMs; }
    public boolean keepsHookRows() { return keepsHookRows; }
    public boolean keepsReportRows() { return keepsReportRows; }
    public List<String> kinds() { return kinds; }
    public UInt64 leftMs() { return leftMs; }
    public String maxSensitivity() { return maxSensitivity; }
    public boolean remote() { return remote; }
    public String streamId() { return streamId; }

    public static ServerStatsJournalFollower fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsJournalFollower");
        Builder builder = builder();
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "ServerStatsJournalFollower.client"));
        Object rawConnectedMs = Wire.required(object, "connected_ms");
        builder.connectedMs(Wire.uint64(rawConnectedMs, "ServerStatsJournalFollower.connected_ms"));
        Object rawKeepsHookRows = Wire.required(object, "keeps_hook_rows");
        builder.keepsHookRows(Wire.bool(rawKeepsHookRows, "ServerStatsJournalFollower.keeps_hook_rows"));
        Object rawKeepsReportRows = Wire.required(object, "keeps_report_rows");
        builder.keepsReportRows(Wire.bool(rawKeepsReportRows, "ServerStatsJournalFollower.keeps_report_rows"));
        Object rawKinds = Wire.required(object, "kinds");
        builder.kinds(Wire.array(rawKinds, "ServerStatsJournalFollower.kinds", item -> Wire.string(item, "ServerStatsJournalFollower.kinds item")));
        Object rawLeftMs = Wire.required(object, "left_ms");
        builder.leftMs(rawLeftMs == null ? null : Wire.uint64(rawLeftMs, "ServerStatsJournalFollower.left_ms"));
        Object rawMaxSensitivity = Wire.required(object, "max_sensitivity");
        builder.maxSensitivity(rawMaxSensitivity == null ? null : Wire.string(rawMaxSensitivity, "ServerStatsJournalFollower.max_sensitivity"));
        Object rawRemote = Wire.required(object, "remote");
        builder.remote(Wire.bool(rawRemote, "ServerStatsJournalFollower.remote"));
        Object rawStreamId = Wire.required(object, "stream_id");
        builder.streamId(Wire.string(rawStreamId, "ServerStatsJournalFollower.stream_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client", client);
        Wire.put(object, "connected_ms", connectedMs);
        Wire.put(object, "keeps_hook_rows", keepsHookRows);
        Wire.put(object, "keeps_report_rows", keepsReportRows);
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "left_ms", leftMs);
        Wire.put(object, "max_sensitivity", maxSensitivity);
        Wire.put(object, "remote", remote);
        Wire.put(object, "stream_id", streamId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsJournalFollower that)) return false;
        return Objects.equals(client, that.client) && Objects.equals(connectedMs, that.connectedMs) && Objects.equals(keepsHookRows, that.keepsHookRows) && Objects.equals(keepsReportRows, that.keepsReportRows) && Objects.equals(kinds, that.kinds) && Objects.equals(leftMs, that.leftMs) && Objects.equals(maxSensitivity, that.maxSensitivity) && Objects.equals(remote, that.remote) && Objects.equals(streamId, that.streamId);
    }

    @Override
    public int hashCode() { return Objects.hash(client, connectedMs, keepsHookRows, keepsReportRows, kinds, leftMs, maxSensitivity, remote, streamId); }

    @Override
    public String toString() { return "ServerStatsJournalFollower" + toWire(); }

    public static final class Builder {
        private UInt64 client;
        private boolean clientSet;
        private UInt64 connectedMs;
        private boolean connectedMsSet;
        private Boolean keepsHookRows;
        private boolean keepsHookRowsSet;
        private Boolean keepsReportRows;
        private boolean keepsReportRowsSet;
        private List<String> kinds;
        private boolean kindsSet;
        private UInt64 leftMs;
        private boolean leftMsSet;
        private String maxSensitivity;
        private boolean maxSensitivitySet;
        private Boolean remote;
        private boolean remoteSet;
        private String streamId;
        private boolean streamIdSet;

        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public Builder connectedMs(UInt64 value) {
            this.connectedMs = value;
            this.connectedMsSet = true;
            return this;
        }
        public Builder keepsHookRows(boolean value) {
            this.keepsHookRows = value;
            this.keepsHookRowsSet = true;
            return this;
        }
        public Builder keepsReportRows(boolean value) {
            this.keepsReportRows = value;
            this.keepsReportRowsSet = true;
            return this;
        }
        public Builder kinds(List<String> value) {
            this.kinds = value;
            this.kindsSet = true;
            return this;
        }
        public Builder leftMs(UInt64 value) {
            this.leftMs = value;
            this.leftMsSet = true;
            return this;
        }
        public Builder maxSensitivity(String value) {
            this.maxSensitivity = value;
            this.maxSensitivitySet = true;
            return this;
        }
        public Builder remote(boolean value) {
            this.remote = value;
            this.remoteSet = true;
            return this;
        }
        public Builder streamId(String value) {
            this.streamId = value;
            this.streamIdSet = true;
            return this;
        }
        public ServerStatsJournalFollower build() { return new ServerStatsJournalFollower(this); }
    }
}

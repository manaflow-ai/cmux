// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsJournalFollowers implements WireValue {
    private final List<ServerStatsJournalFollower> followers;
    private final UInt64 graceMs;
    private final boolean hookRowsKept;
    private final Boolean journalHookKeepsRows;
    private final UInt64 keepAllMs;
    private final boolean reportRowsKept;

    private ServerStatsJournalFollowers(Builder builder) {
        if (!builder.followersSet) throw new IllegalArgumentException("followers is required");
        this.followers = List.copyOf(Wire.nonNull(builder.followers, "followers"));
        if (!builder.graceMsSet) throw new IllegalArgumentException("grace_ms is required");
        this.graceMs = Wire.nonNull(builder.graceMs, "grace_ms");
        if (!builder.hookRowsKeptSet) throw new IllegalArgumentException("hook_rows_kept is required");
        this.hookRowsKept = builder.hookRowsKept;
        if (!builder.journalHookKeepsRowsSet) throw new IllegalArgumentException("journal_hook_keeps_rows is required");
        this.journalHookKeepsRows = builder.journalHookKeepsRows;
        if (!builder.keepAllMsSet) throw new IllegalArgumentException("keep_all_ms is required");
        this.keepAllMs = Wire.nonNull(builder.keepAllMs, "keep_all_ms");
        if (!builder.reportRowsKeptSet) throw new IllegalArgumentException("report_rows_kept is required");
        this.reportRowsKept = builder.reportRowsKept;
    }

    public static Builder builder() { return new Builder(); }

    public List<ServerStatsJournalFollower> followers() { return followers; }
    public UInt64 graceMs() { return graceMs; }
    public boolean hookRowsKept() { return hookRowsKept; }
    public Boolean journalHookKeepsRows() { return journalHookKeepsRows; }
    public UInt64 keepAllMs() { return keepAllMs; }
    public boolean reportRowsKept() { return reportRowsKept; }

    public static ServerStatsJournalFollowers fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsJournalFollowers");
        Builder builder = builder();
        Object rawFollowers = Wire.required(object, "followers");
        builder.followers(Wire.array(rawFollowers, "ServerStatsJournalFollowers.followers", item -> ServerStatsJournalFollower.fromWire(item)));
        Object rawGraceMs = Wire.required(object, "grace_ms");
        builder.graceMs(Wire.uint64(rawGraceMs, "ServerStatsJournalFollowers.grace_ms"));
        Object rawHookRowsKept = Wire.required(object, "hook_rows_kept");
        builder.hookRowsKept(Wire.bool(rawHookRowsKept, "ServerStatsJournalFollowers.hook_rows_kept"));
        Object rawJournalHookKeepsRows = Wire.required(object, "journal_hook_keeps_rows");
        builder.journalHookKeepsRows(rawJournalHookKeepsRows == null ? null : Wire.bool(rawJournalHookKeepsRows, "ServerStatsJournalFollowers.journal_hook_keeps_rows"));
        Object rawKeepAllMs = Wire.required(object, "keep_all_ms");
        builder.keepAllMs(Wire.uint64(rawKeepAllMs, "ServerStatsJournalFollowers.keep_all_ms"));
        Object rawReportRowsKept = Wire.required(object, "report_rows_kept");
        builder.reportRowsKept(Wire.bool(rawReportRowsKept, "ServerStatsJournalFollowers.report_rows_kept"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "followers", followers);
        Wire.put(object, "grace_ms", graceMs);
        Wire.put(object, "hook_rows_kept", hookRowsKept);
        Wire.put(object, "journal_hook_keeps_rows", journalHookKeepsRows);
        Wire.put(object, "keep_all_ms", keepAllMs);
        Wire.put(object, "report_rows_kept", reportRowsKept);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsJournalFollowers that)) return false;
        return Objects.equals(followers, that.followers) && Objects.equals(graceMs, that.graceMs) && Objects.equals(hookRowsKept, that.hookRowsKept) && Objects.equals(journalHookKeepsRows, that.journalHookKeepsRows) && Objects.equals(keepAllMs, that.keepAllMs) && Objects.equals(reportRowsKept, that.reportRowsKept);
    }

    @Override
    public int hashCode() { return Objects.hash(followers, graceMs, hookRowsKept, journalHookKeepsRows, keepAllMs, reportRowsKept); }

    @Override
    public String toString() { return "ServerStatsJournalFollowers" + toWire(); }

    public static final class Builder {
        private List<ServerStatsJournalFollower> followers;
        private boolean followersSet;
        private UInt64 graceMs;
        private boolean graceMsSet;
        private Boolean hookRowsKept;
        private boolean hookRowsKeptSet;
        private Boolean journalHookKeepsRows;
        private boolean journalHookKeepsRowsSet;
        private UInt64 keepAllMs;
        private boolean keepAllMsSet;
        private Boolean reportRowsKept;
        private boolean reportRowsKeptSet;

        public Builder followers(List<ServerStatsJournalFollower> value) {
            this.followers = value;
            this.followersSet = true;
            return this;
        }
        public Builder graceMs(UInt64 value) {
            this.graceMs = value;
            this.graceMsSet = true;
            return this;
        }
        public Builder hookRowsKept(boolean value) {
            this.hookRowsKept = value;
            this.hookRowsKeptSet = true;
            return this;
        }
        public Builder journalHookKeepsRows(Boolean value) {
            this.journalHookKeepsRows = value;
            this.journalHookKeepsRowsSet = true;
            return this;
        }
        public Builder keepAllMs(UInt64 value) {
            this.keepAllMs = value;
            this.keepAllMsSet = true;
            return this;
        }
        public Builder reportRowsKept(boolean value) {
            this.reportRowsKept = value;
            this.reportRowsKeptSet = true;
            return this;
        }
        public ServerStatsJournalFollowers build() { return new ServerStatsJournalFollowers(this); }
    }
}

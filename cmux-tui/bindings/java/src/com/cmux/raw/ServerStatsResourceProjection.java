// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsResourceProjection implements WireValue {
    private final ServerStatsHistogram commitApplyUs;
    private final ServerStatsHistogram commitJournalUs;
    private final ServerStatsHistogram commitPruneUs;
    private final ServerStatsHistogram commitUs;
    private final UInt64 commits;
    private final ServerStatsHistogram diffUs;
    private final ServerStatsHistogram indexUs;
    private final ServerStatsHistogram journaledChanges;
    private final ServerStatsHistogram projectedChanges;
    private final UInt64 projections;
    private final ServerStatsHistogram readUs;
    private final ServerStatsHistogram writtenChanges;

    private ServerStatsResourceProjection(Builder builder) {
        if (!builder.commitApplyUsSet) throw new IllegalArgumentException("commit_apply_us is required");
        this.commitApplyUs = Wire.nonNull(builder.commitApplyUs, "commit_apply_us");
        if (!builder.commitJournalUsSet) throw new IllegalArgumentException("commit_journal_us is required");
        this.commitJournalUs = Wire.nonNull(builder.commitJournalUs, "commit_journal_us");
        if (!builder.commitPruneUsSet) throw new IllegalArgumentException("commit_prune_us is required");
        this.commitPruneUs = Wire.nonNull(builder.commitPruneUs, "commit_prune_us");
        if (!builder.commitUsSet) throw new IllegalArgumentException("commit_us is required");
        this.commitUs = Wire.nonNull(builder.commitUs, "commit_us");
        if (!builder.commitsSet) throw new IllegalArgumentException("commits is required");
        this.commits = Wire.nonNull(builder.commits, "commits");
        if (!builder.diffUsSet) throw new IllegalArgumentException("diff_us is required");
        this.diffUs = Wire.nonNull(builder.diffUs, "diff_us");
        if (!builder.indexUsSet) throw new IllegalArgumentException("index_us is required");
        this.indexUs = Wire.nonNull(builder.indexUs, "index_us");
        if (!builder.journaledChangesSet) throw new IllegalArgumentException("journaled_changes is required");
        this.journaledChanges = Wire.nonNull(builder.journaledChanges, "journaled_changes");
        if (!builder.projectedChangesSet) throw new IllegalArgumentException("projected_changes is required");
        this.projectedChanges = Wire.nonNull(builder.projectedChanges, "projected_changes");
        if (!builder.projectionsSet) throw new IllegalArgumentException("projections is required");
        this.projections = Wire.nonNull(builder.projections, "projections");
        if (!builder.readUsSet) throw new IllegalArgumentException("read_us is required");
        this.readUs = Wire.nonNull(builder.readUs, "read_us");
        if (!builder.writtenChangesSet) throw new IllegalArgumentException("written_changes is required");
        this.writtenChanges = Wire.nonNull(builder.writtenChanges, "written_changes");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsHistogram commitApplyUs() { return commitApplyUs; }
    public ServerStatsHistogram commitJournalUs() { return commitJournalUs; }
    public ServerStatsHistogram commitPruneUs() { return commitPruneUs; }
    public ServerStatsHistogram commitUs() { return commitUs; }
    public UInt64 commits() { return commits; }
    public ServerStatsHistogram diffUs() { return diffUs; }
    public ServerStatsHistogram indexUs() { return indexUs; }
    public ServerStatsHistogram journaledChanges() { return journaledChanges; }
    public ServerStatsHistogram projectedChanges() { return projectedChanges; }
    public UInt64 projections() { return projections; }
    public ServerStatsHistogram readUs() { return readUs; }
    public ServerStatsHistogram writtenChanges() { return writtenChanges; }

    public static ServerStatsResourceProjection fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsResourceProjection");
        Builder builder = builder();
        Object rawCommitApplyUs = Wire.required(object, "commit_apply_us");
        builder.commitApplyUs(ServerStatsHistogram.fromWire(rawCommitApplyUs));
        Object rawCommitJournalUs = Wire.required(object, "commit_journal_us");
        builder.commitJournalUs(ServerStatsHistogram.fromWire(rawCommitJournalUs));
        Object rawCommitPruneUs = Wire.required(object, "commit_prune_us");
        builder.commitPruneUs(ServerStatsHistogram.fromWire(rawCommitPruneUs));
        Object rawCommitUs = Wire.required(object, "commit_us");
        builder.commitUs(ServerStatsHistogram.fromWire(rawCommitUs));
        Object rawCommits = Wire.required(object, "commits");
        builder.commits(Wire.uint64(rawCommits, "ServerStatsResourceProjection.commits"));
        Object rawDiffUs = Wire.required(object, "diff_us");
        builder.diffUs(ServerStatsHistogram.fromWire(rawDiffUs));
        Object rawIndexUs = Wire.required(object, "index_us");
        builder.indexUs(ServerStatsHistogram.fromWire(rawIndexUs));
        Object rawJournaledChanges = Wire.required(object, "journaled_changes");
        builder.journaledChanges(ServerStatsHistogram.fromWire(rawJournaledChanges));
        Object rawProjectedChanges = Wire.required(object, "projected_changes");
        builder.projectedChanges(ServerStatsHistogram.fromWire(rawProjectedChanges));
        Object rawProjections = Wire.required(object, "projections");
        builder.projections(Wire.uint64(rawProjections, "ServerStatsResourceProjection.projections"));
        Object rawReadUs = Wire.required(object, "read_us");
        builder.readUs(ServerStatsHistogram.fromWire(rawReadUs));
        Object rawWrittenChanges = Wire.required(object, "written_changes");
        builder.writtenChanges(ServerStatsHistogram.fromWire(rawWrittenChanges));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "commit_apply_us", commitApplyUs);
        Wire.put(object, "commit_journal_us", commitJournalUs);
        Wire.put(object, "commit_prune_us", commitPruneUs);
        Wire.put(object, "commit_us", commitUs);
        Wire.put(object, "commits", commits);
        Wire.put(object, "diff_us", diffUs);
        Wire.put(object, "index_us", indexUs);
        Wire.put(object, "journaled_changes", journaledChanges);
        Wire.put(object, "projected_changes", projectedChanges);
        Wire.put(object, "projections", projections);
        Wire.put(object, "read_us", readUs);
        Wire.put(object, "written_changes", writtenChanges);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsResourceProjection that)) return false;
        return Objects.equals(commitApplyUs, that.commitApplyUs) && Objects.equals(commitJournalUs, that.commitJournalUs) && Objects.equals(commitPruneUs, that.commitPruneUs) && Objects.equals(commitUs, that.commitUs) && Objects.equals(commits, that.commits) && Objects.equals(diffUs, that.diffUs) && Objects.equals(indexUs, that.indexUs) && Objects.equals(journaledChanges, that.journaledChanges) && Objects.equals(projectedChanges, that.projectedChanges) && Objects.equals(projections, that.projections) && Objects.equals(readUs, that.readUs) && Objects.equals(writtenChanges, that.writtenChanges);
    }

    @Override
    public int hashCode() { return Objects.hash(commitApplyUs, commitJournalUs, commitPruneUs, commitUs, commits, diffUs, indexUs, journaledChanges, projectedChanges, projections, readUs, writtenChanges); }

    @Override
    public String toString() { return "ServerStatsResourceProjection" + toWire(); }

    public static final class Builder {
        private ServerStatsHistogram commitApplyUs;
        private boolean commitApplyUsSet;
        private ServerStatsHistogram commitJournalUs;
        private boolean commitJournalUsSet;
        private ServerStatsHistogram commitPruneUs;
        private boolean commitPruneUsSet;
        private ServerStatsHistogram commitUs;
        private boolean commitUsSet;
        private UInt64 commits;
        private boolean commitsSet;
        private ServerStatsHistogram diffUs;
        private boolean diffUsSet;
        private ServerStatsHistogram indexUs;
        private boolean indexUsSet;
        private ServerStatsHistogram journaledChanges;
        private boolean journaledChangesSet;
        private ServerStatsHistogram projectedChanges;
        private boolean projectedChangesSet;
        private UInt64 projections;
        private boolean projectionsSet;
        private ServerStatsHistogram readUs;
        private boolean readUsSet;
        private ServerStatsHistogram writtenChanges;
        private boolean writtenChangesSet;

        public Builder commitApplyUs(ServerStatsHistogram value) {
            this.commitApplyUs = value;
            this.commitApplyUsSet = true;
            return this;
        }
        public Builder commitJournalUs(ServerStatsHistogram value) {
            this.commitJournalUs = value;
            this.commitJournalUsSet = true;
            return this;
        }
        public Builder commitPruneUs(ServerStatsHistogram value) {
            this.commitPruneUs = value;
            this.commitPruneUsSet = true;
            return this;
        }
        public Builder commitUs(ServerStatsHistogram value) {
            this.commitUs = value;
            this.commitUsSet = true;
            return this;
        }
        public Builder commits(UInt64 value) {
            this.commits = value;
            this.commitsSet = true;
            return this;
        }
        public Builder diffUs(ServerStatsHistogram value) {
            this.diffUs = value;
            this.diffUsSet = true;
            return this;
        }
        public Builder indexUs(ServerStatsHistogram value) {
            this.indexUs = value;
            this.indexUsSet = true;
            return this;
        }
        public Builder journaledChanges(ServerStatsHistogram value) {
            this.journaledChanges = value;
            this.journaledChangesSet = true;
            return this;
        }
        public Builder projectedChanges(ServerStatsHistogram value) {
            this.projectedChanges = value;
            this.projectedChangesSet = true;
            return this;
        }
        public Builder projections(UInt64 value) {
            this.projections = value;
            this.projectionsSet = true;
            return this;
        }
        public Builder readUs(ServerStatsHistogram value) {
            this.readUs = value;
            this.readUsSet = true;
            return this;
        }
        public Builder writtenChanges(ServerStatsHistogram value) {
            this.writtenChanges = value;
            this.writtenChangesSet = true;
            return this;
        }
        public ServerStatsResourceProjection build() { return new ServerStatsResourceProjection(this); }
    }
}

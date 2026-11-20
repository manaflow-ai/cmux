// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsWritePathWriter implements WireValue {
    private final UInt64 commits;
    private final UInt64 walFrames;
    private final String writer;

    private ServerStatsWritePathWriter(Builder builder) {
        if (!builder.commitsSet) throw new IllegalArgumentException("commits is required");
        this.commits = Wire.nonNull(builder.commits, "commits");
        if (!builder.walFramesSet) throw new IllegalArgumentException("wal_frames is required");
        this.walFrames = Wire.nonNull(builder.walFrames, "wal_frames");
        if (!builder.writerSet) throw new IllegalArgumentException("writer is required");
        this.writer = Wire.nonNull(builder.writer, "writer");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 commits() { return commits; }
    public UInt64 walFrames() { return walFrames; }
    public String writer() { return writer; }

    public static ServerStatsWritePathWriter fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsWritePathWriter");
        Builder builder = builder();
        Object rawCommits = Wire.required(object, "commits");
        builder.commits(Wire.uint64(rawCommits, "ServerStatsWritePathWriter.commits"));
        Object rawWalFrames = Wire.required(object, "wal_frames");
        builder.walFrames(Wire.uint64(rawWalFrames, "ServerStatsWritePathWriter.wal_frames"));
        Object rawWriter = Wire.required(object, "writer");
        builder.writer(Wire.string(rawWriter, "ServerStatsWritePathWriter.writer"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "commits", commits);
        Wire.put(object, "wal_frames", walFrames);
        Wire.put(object, "writer", writer);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsWritePathWriter that)) return false;
        return Objects.equals(commits, that.commits) && Objects.equals(walFrames, that.walFrames) && Objects.equals(writer, that.writer);
    }

    @Override
    public int hashCode() { return Objects.hash(commits, walFrames, writer); }

    @Override
    public String toString() { return "ServerStatsWritePathWriter" + toWire(); }

    public static final class Builder {
        private UInt64 commits;
        private boolean commitsSet;
        private UInt64 walFrames;
        private boolean walFramesSet;
        private String writer;
        private boolean writerSet;

        public Builder commits(UInt64 value) {
            this.commits = value;
            this.commitsSet = true;
            return this;
        }
        public Builder walFrames(UInt64 value) {
            this.walFrames = value;
            this.walFramesSet = true;
            return this;
        }
        public Builder writer(String value) {
            this.writer = value;
            this.writerSet = true;
            return this;
        }
        public ServerStatsWritePathWriter build() { return new ServerStatsWritePathWriter(this); }
    }
}

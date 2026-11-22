// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskJournal implements WireValue {
    private final UInt64 estimatedLiveBytes;
    private final UInt64 firstSequence;
    private final UInt64 headSequence;
    private final List<ServerStatsDiskJournalKind> kinds;
    private final UInt64 liveRows;
    private final UInt64 sampleBytes;
    private final UInt64 sampleRows;
    private final UInt64 sampleSpanMs;

    private ServerStatsDiskJournal(Builder builder) {
        if (!builder.estimatedLiveBytesSet) throw new IllegalArgumentException("estimated_live_bytes is required");
        this.estimatedLiveBytes = Wire.nonNull(builder.estimatedLiveBytes, "estimated_live_bytes");
        if (!builder.firstSequenceSet) throw new IllegalArgumentException("first_sequence is required");
        this.firstSequence = Wire.nonNull(builder.firstSequence, "first_sequence");
        if (!builder.headSequenceSet) throw new IllegalArgumentException("head_sequence is required");
        this.headSequence = Wire.nonNull(builder.headSequence, "head_sequence");
        if (!builder.kindsSet) throw new IllegalArgumentException("kinds is required");
        this.kinds = List.copyOf(Wire.nonNull(builder.kinds, "kinds"));
        if (!builder.liveRowsSet) throw new IllegalArgumentException("live_rows is required");
        this.liveRows = Wire.nonNull(builder.liveRows, "live_rows");
        if (!builder.sampleBytesSet) throw new IllegalArgumentException("sample_bytes is required");
        this.sampleBytes = Wire.nonNull(builder.sampleBytes, "sample_bytes");
        if (!builder.sampleRowsSet) throw new IllegalArgumentException("sample_rows is required");
        this.sampleRows = Wire.nonNull(builder.sampleRows, "sample_rows");
        if (!builder.sampleSpanMsSet) throw new IllegalArgumentException("sample_span_ms is required");
        this.sampleSpanMs = Wire.nonNull(builder.sampleSpanMs, "sample_span_ms");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 estimatedLiveBytes() { return estimatedLiveBytes; }
    public UInt64 firstSequence() { return firstSequence; }
    public UInt64 headSequence() { return headSequence; }
    public List<ServerStatsDiskJournalKind> kinds() { return kinds; }
    public UInt64 liveRows() { return liveRows; }
    public UInt64 sampleBytes() { return sampleBytes; }
    public UInt64 sampleRows() { return sampleRows; }
    public UInt64 sampleSpanMs() { return sampleSpanMs; }

    public static ServerStatsDiskJournal fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskJournal");
        Builder builder = builder();
        Object rawEstimatedLiveBytes = Wire.required(object, "estimated_live_bytes");
        builder.estimatedLiveBytes(Wire.uint64(rawEstimatedLiveBytes, "ServerStatsDiskJournal.estimated_live_bytes"));
        Object rawFirstSequence = Wire.required(object, "first_sequence");
        builder.firstSequence(Wire.uint64(rawFirstSequence, "ServerStatsDiskJournal.first_sequence"));
        Object rawHeadSequence = Wire.required(object, "head_sequence");
        builder.headSequence(Wire.uint64(rawHeadSequence, "ServerStatsDiskJournal.head_sequence"));
        Object rawKinds = Wire.required(object, "kinds");
        builder.kinds(Wire.array(rawKinds, "ServerStatsDiskJournal.kinds", item -> ServerStatsDiskJournalKind.fromWire(item)));
        Object rawLiveRows = Wire.required(object, "live_rows");
        builder.liveRows(Wire.uint64(rawLiveRows, "ServerStatsDiskJournal.live_rows"));
        Object rawSampleBytes = Wire.required(object, "sample_bytes");
        builder.sampleBytes(Wire.uint64(rawSampleBytes, "ServerStatsDiskJournal.sample_bytes"));
        Object rawSampleRows = Wire.required(object, "sample_rows");
        builder.sampleRows(Wire.uint64(rawSampleRows, "ServerStatsDiskJournal.sample_rows"));
        Object rawSampleSpanMs = Wire.required(object, "sample_span_ms");
        builder.sampleSpanMs(Wire.uint64(rawSampleSpanMs, "ServerStatsDiskJournal.sample_span_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "estimated_live_bytes", estimatedLiveBytes);
        Wire.put(object, "first_sequence", firstSequence);
        Wire.put(object, "head_sequence", headSequence);
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "live_rows", liveRows);
        Wire.put(object, "sample_bytes", sampleBytes);
        Wire.put(object, "sample_rows", sampleRows);
        Wire.put(object, "sample_span_ms", sampleSpanMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskJournal that)) return false;
        return Objects.equals(estimatedLiveBytes, that.estimatedLiveBytes) && Objects.equals(firstSequence, that.firstSequence) && Objects.equals(headSequence, that.headSequence) && Objects.equals(kinds, that.kinds) && Objects.equals(liveRows, that.liveRows) && Objects.equals(sampleBytes, that.sampleBytes) && Objects.equals(sampleRows, that.sampleRows) && Objects.equals(sampleSpanMs, that.sampleSpanMs);
    }

    @Override
    public int hashCode() { return Objects.hash(estimatedLiveBytes, firstSequence, headSequence, kinds, liveRows, sampleBytes, sampleRows, sampleSpanMs); }

    @Override
    public String toString() { return "ServerStatsDiskJournal" + toWire(); }

    public static final class Builder {
        private UInt64 estimatedLiveBytes;
        private boolean estimatedLiveBytesSet;
        private UInt64 firstSequence;
        private boolean firstSequenceSet;
        private UInt64 headSequence;
        private boolean headSequenceSet;
        private List<ServerStatsDiskJournalKind> kinds;
        private boolean kindsSet;
        private UInt64 liveRows;
        private boolean liveRowsSet;
        private UInt64 sampleBytes;
        private boolean sampleBytesSet;
        private UInt64 sampleRows;
        private boolean sampleRowsSet;
        private UInt64 sampleSpanMs;
        private boolean sampleSpanMsSet;

        public Builder estimatedLiveBytes(UInt64 value) {
            this.estimatedLiveBytes = value;
            this.estimatedLiveBytesSet = true;
            return this;
        }
        public Builder firstSequence(UInt64 value) {
            this.firstSequence = value;
            this.firstSequenceSet = true;
            return this;
        }
        public Builder headSequence(UInt64 value) {
            this.headSequence = value;
            this.headSequenceSet = true;
            return this;
        }
        public Builder kinds(List<ServerStatsDiskJournalKind> value) {
            this.kinds = value;
            this.kindsSet = true;
            return this;
        }
        public Builder liveRows(UInt64 value) {
            this.liveRows = value;
            this.liveRowsSet = true;
            return this;
        }
        public Builder sampleBytes(UInt64 value) {
            this.sampleBytes = value;
            this.sampleBytesSet = true;
            return this;
        }
        public Builder sampleRows(UInt64 value) {
            this.sampleRows = value;
            this.sampleRowsSet = true;
            return this;
        }
        public Builder sampleSpanMs(UInt64 value) {
            this.sampleSpanMs = value;
            this.sampleSpanMsSet = true;
            return this;
        }
        public ServerStatsDiskJournal build() { return new ServerStatsDiskJournal(this); }
    }
}

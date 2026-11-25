// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable attach-surface request. Protocol v5; authority: frontend. */
public final class AttachSurfaceRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<String> expectedGeneration;
    private final Field<String> expectedTerminalId;
    private final Field<UInt64> hybridFrame;
    private final Field<String> hybridStream;
    private final Field<AttachSurfaceRequestMode> mode;
    private final Field<Long> outputCoalesceMs;
    private final Field<Long> replayHistoryRows;
    private final Field<UInt64> replayHistoryStart;
    private final Field<String> resumeGeneration;
    private final Field<UInt64> resumeMaxBytes;
    private final Field<UInt64> resumeOffset;
    private final Field<Integer> rows;
    private final Field<String> snapshot;
    private final Field<Boolean> snapshotImages;
    private final Field<Boolean> snapshotLocalHistory;
    private final Field<Integer> snapshotVersion;
    private final Field<UInt64> surface;
    private final Field<UInt64> viewerBacklogBytes;

    private AttachSurfaceRequest(Builder builder) {
        this.cols = builder.cols;
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedTerminalId = builder.expectedTerminalId;
        this.hybridFrame = builder.hybridFrame;
        this.hybridStream = builder.hybridStream;
        this.mode = builder.mode;
        this.outputCoalesceMs = builder.outputCoalesceMs;
        this.replayHistoryRows = builder.replayHistoryRows;
        this.replayHistoryStart = builder.replayHistoryStart;
        this.resumeGeneration = builder.resumeGeneration;
        this.resumeMaxBytes = builder.resumeMaxBytes;
        this.resumeOffset = builder.resumeOffset;
        this.rows = builder.rows;
        this.snapshot = builder.snapshot;
        this.snapshotImages = builder.snapshotImages;
        this.snapshotLocalHistory = builder.snapshotLocalHistory;
        this.snapshotVersion = builder.snapshotVersion;
        this.surface = builder.surface;
        this.viewerBacklogBytes = builder.viewerBacklogBytes;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<String> expectedTerminalId() { return expectedTerminalId; }
    public Field<UInt64> hybridFrame() { return hybridFrame; }
    public Field<String> hybridStream() { return hybridStream; }
    public Field<AttachSurfaceRequestMode> mode() { return mode; }
    public Field<Long> outputCoalesceMs() { return outputCoalesceMs; }
    public Field<Long> replayHistoryRows() { return replayHistoryRows; }
    public Field<UInt64> replayHistoryStart() { return replayHistoryStart; }
    public Field<String> resumeGeneration() { return resumeGeneration; }
    public Field<UInt64> resumeMaxBytes() { return resumeMaxBytes; }
    public Field<UInt64> resumeOffset() { return resumeOffset; }
    public Field<Integer> rows() { return rows; }
    public Field<String> snapshot() { return snapshot; }
    public Field<Boolean> snapshotImages() { return snapshotImages; }
    public Field<Boolean> snapshotLocalHistory() { return snapshotLocalHistory; }
    public Field<Integer> snapshotVersion() { return snapshotVersion; }
    public Field<UInt64> surface() { return surface; }
    public Field<UInt64> viewerBacklogBytes() { return viewerBacklogBytes; }

    public static AttachSurfaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AttachSurfaceRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "AttachSurfaceRequest.cols"));
        }
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "AttachSurfaceRequest.expected_generation"));
        }
        Object rawExpectedTerminalId = Wire.optional(object, "expected_terminal_id");
        if (!Wire.isMissing(rawExpectedTerminalId)) {
            builder.expectedTerminalId(rawExpectedTerminalId == null ? null : Wire.string(rawExpectedTerminalId, "AttachSurfaceRequest.expected_terminal_id"));
        }
        Object rawHybridFrame = Wire.optional(object, "hybrid_frame");
        if (!Wire.isMissing(rawHybridFrame)) {
            builder.hybridFrame(rawHybridFrame == null ? null : Wire.uint64(rawHybridFrame, "AttachSurfaceRequest.hybrid_frame"));
        }
        Object rawHybridStream = Wire.optional(object, "hybrid_stream");
        if (!Wire.isMissing(rawHybridStream)) {
            builder.hybridStream(rawHybridStream == null ? null : Wire.string(rawHybridStream, "AttachSurfaceRequest.hybrid_stream"));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : AttachSurfaceRequestMode.fromWire(rawMode));
        }
        Object rawOutputCoalesceMs = Wire.optional(object, "output_coalesce_ms");
        if (!Wire.isMissing(rawOutputCoalesceMs)) {
            builder.outputCoalesceMs(rawOutputCoalesceMs == null ? null : Wire.uint32(rawOutputCoalesceMs, "AttachSurfaceRequest.output_coalesce_ms"));
        }
        Object rawReplayHistoryRows = Wire.optional(object, "replay_history_rows");
        if (!Wire.isMissing(rawReplayHistoryRows)) {
            builder.replayHistoryRows(rawReplayHistoryRows == null ? null : Wire.uint32(rawReplayHistoryRows, "AttachSurfaceRequest.replay_history_rows"));
        }
        Object rawReplayHistoryStart = Wire.optional(object, "replay_history_start");
        if (!Wire.isMissing(rawReplayHistoryStart)) {
            builder.replayHistoryStart(rawReplayHistoryStart == null ? null : Wire.uint64(rawReplayHistoryStart, "AttachSurfaceRequest.replay_history_start"));
        }
        Object rawResumeGeneration = Wire.optional(object, "resume_generation");
        if (!Wire.isMissing(rawResumeGeneration)) {
            builder.resumeGeneration(rawResumeGeneration == null ? null : Wire.string(rawResumeGeneration, "AttachSurfaceRequest.resume_generation"));
        }
        Object rawResumeMaxBytes = Wire.optional(object, "resume_max_bytes");
        if (!Wire.isMissing(rawResumeMaxBytes)) {
            builder.resumeMaxBytes(rawResumeMaxBytes == null ? null : Wire.uint64(rawResumeMaxBytes, "AttachSurfaceRequest.resume_max_bytes"));
        }
        Object rawResumeOffset = Wire.optional(object, "resume_offset");
        if (!Wire.isMissing(rawResumeOffset)) {
            builder.resumeOffset(rawResumeOffset == null ? null : Wire.uint64(rawResumeOffset, "AttachSurfaceRequest.resume_offset"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "AttachSurfaceRequest.rows"));
        }
        Object rawSnapshot = Wire.optional(object, "snapshot");
        if (!Wire.isMissing(rawSnapshot)) {
            builder.snapshot(rawSnapshot == null ? null : Wire.string(rawSnapshot, "AttachSurfaceRequest.snapshot"));
        }
        Object rawSnapshotImages = Wire.optional(object, "snapshot_images");
        if (!Wire.isMissing(rawSnapshotImages)) {
            builder.snapshotImages(Wire.bool(rawSnapshotImages, "AttachSurfaceRequest.snapshot_images"));
        }
        Object rawSnapshotLocalHistory = Wire.optional(object, "snapshot_local_history");
        if (!Wire.isMissing(rawSnapshotLocalHistory)) {
            builder.snapshotLocalHistory(Wire.bool(rawSnapshotLocalHistory, "AttachSurfaceRequest.snapshot_local_history"));
        }
        Object rawSnapshotVersion = Wire.optional(object, "snapshot_version");
        if (!Wire.isMissing(rawSnapshotVersion)) {
            builder.snapshotVersion(rawSnapshotVersion == null ? null : Wire.uint16(rawSnapshotVersion, "AttachSurfaceRequest.snapshot_version"));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "AttachSurfaceRequest.surface"));
        }
        Object rawViewerBacklogBytes = Wire.optional(object, "viewer_backlog_bytes");
        if (!Wire.isMissing(rawViewerBacklogBytes)) {
            builder.viewerBacklogBytes(rawViewerBacklogBytes == null ? null : Wire.uint64(rawViewerBacklogBytes, "AttachSurfaceRequest.viewer_backlog_bytes"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_terminal_id", expectedTerminalId);
        Wire.put(object, "hybrid_frame", hybridFrame);
        Wire.put(object, "hybrid_stream", hybridStream);
        Wire.put(object, "mode", mode);
        Wire.put(object, "output_coalesce_ms", outputCoalesceMs);
        Wire.put(object, "replay_history_rows", replayHistoryRows);
        Wire.put(object, "replay_history_start", replayHistoryStart);
        Wire.put(object, "resume_generation", resumeGeneration);
        Wire.put(object, "resume_max_bytes", resumeMaxBytes);
        Wire.put(object, "resume_offset", resumeOffset);
        Wire.put(object, "rows", rows);
        Wire.put(object, "snapshot", snapshot);
        Wire.put(object, "snapshot_images", snapshotImages);
        Wire.put(object, "snapshot_local_history", snapshotLocalHistory);
        Wire.put(object, "snapshot_version", snapshotVersion);
        Wire.put(object, "surface", surface);
        Wire.put(object, "viewer_backlog_bytes", viewerBacklogBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AttachSurfaceRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedTerminalId, that.expectedTerminalId) && Objects.equals(hybridFrame, that.hybridFrame) && Objects.equals(hybridStream, that.hybridStream) && Objects.equals(mode, that.mode) && Objects.equals(outputCoalesceMs, that.outputCoalesceMs) && Objects.equals(replayHistoryRows, that.replayHistoryRows) && Objects.equals(replayHistoryStart, that.replayHistoryStart) && Objects.equals(resumeGeneration, that.resumeGeneration) && Objects.equals(resumeMaxBytes, that.resumeMaxBytes) && Objects.equals(resumeOffset, that.resumeOffset) && Objects.equals(rows, that.rows) && Objects.equals(snapshot, that.snapshot) && Objects.equals(snapshotImages, that.snapshotImages) && Objects.equals(snapshotLocalHistory, that.snapshotLocalHistory) && Objects.equals(snapshotVersion, that.snapshotVersion) && Objects.equals(surface, that.surface) && Objects.equals(viewerBacklogBytes, that.viewerBacklogBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, expectedGeneration, expectedTerminalId, hybridFrame, hybridStream, mode, outputCoalesceMs, replayHistoryRows, replayHistoryStart, resumeGeneration, resumeMaxBytes, resumeOffset, rows, snapshot, snapshotImages, snapshotLocalHistory, snapshotVersion, surface, viewerBacklogBytes); }

    @Override
    public String toString() { return "AttachSurfaceRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<String> expectedGeneration = Field.omitted();
        private Field<String> expectedTerminalId = Field.omitted();
        private Field<UInt64> hybridFrame = Field.omitted();
        private Field<String> hybridStream = Field.omitted();
        private Field<AttachSurfaceRequestMode> mode = Field.omitted();
        private Field<Long> outputCoalesceMs = Field.omitted();
        private Field<Long> replayHistoryRows = Field.omitted();
        private Field<UInt64> replayHistoryStart = Field.omitted();
        private Field<String> resumeGeneration = Field.omitted();
        private Field<UInt64> resumeMaxBytes = Field.omitted();
        private Field<UInt64> resumeOffset = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<String> snapshot = Field.omitted();
        private Field<Boolean> snapshotImages = Field.omitted();
        private Field<Boolean> snapshotLocalHistory = Field.omitted();
        private Field<Integer> snapshotVersion = Field.omitted();
        private Field<UInt64> surface = Field.omitted();
        private Field<UInt64> viewerBacklogBytes = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedTerminalId(String value) {
            this.expectedTerminalId = Field.ofNullable(value);
            return this;
        }
        public Builder hybridFrame(UInt64 value) {
            this.hybridFrame = Field.ofNullable(value);
            return this;
        }
        public Builder hybridStream(String value) {
            this.hybridStream = Field.ofNullable(value);
            return this;
        }
        public Builder mode(AttachSurfaceRequestMode value) {
            this.mode = Field.ofNullable(value);
            return this;
        }
        public Builder outputCoalesceMs(Long value) {
            this.outputCoalesceMs = Field.ofNullable(value);
            return this;
        }
        public Builder replayHistoryRows(Long value) {
            this.replayHistoryRows = Field.ofNullable(value);
            return this;
        }
        public Builder replayHistoryStart(UInt64 value) {
            this.replayHistoryStart = Field.ofNullable(value);
            return this;
        }
        public Builder resumeGeneration(String value) {
            this.resumeGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder resumeMaxBytes(UInt64 value) {
            this.resumeMaxBytes = Field.ofNullable(value);
            return this;
        }
        public Builder resumeOffset(UInt64 value) {
            this.resumeOffset = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder snapshot(String value) {
            this.snapshot = Field.ofNullable(value);
            return this;
        }
        public Builder snapshotImages(Boolean value) {
            this.snapshotImages = Field.of(value);
            return this;
        }
        public Builder snapshotLocalHistory(Boolean value) {
            this.snapshotLocalHistory = Field.of(value);
            return this;
        }
        public Builder snapshotVersion(Integer value) {
            this.snapshotVersion = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder viewerBacklogBytes(UInt64 value) {
            this.viewerBacklogBytes = Field.ofNullable(value);
            return this;
        }
        public AttachSurfaceRequest build() { return new AttachSurfaceRequest(this); }
    }
}

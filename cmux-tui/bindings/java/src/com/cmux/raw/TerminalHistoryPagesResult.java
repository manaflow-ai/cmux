// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalHistoryPagesResult implements WireValue {
    private final boolean done;
    private final UInt64 markerEpoch;
    private final Field<UInt64> nextBefore;
    private final List<TerminalHistoryPage> pages;
    private final int snapshotVersion;
    private final UInt64 surface;

    private TerminalHistoryPagesResult(Builder builder) {
        if (!builder.doneSet) throw new IllegalArgumentException("done is required");
        this.done = builder.done;
        if (!builder.markerEpochSet) throw new IllegalArgumentException("marker_epoch is required");
        this.markerEpoch = Wire.nonNull(builder.markerEpoch, "marker_epoch");
        this.nextBefore = builder.nextBefore;
        if (!builder.pagesSet) throw new IllegalArgumentException("pages is required");
        this.pages = List.copyOf(Wire.nonNull(builder.pages, "pages"));
        if (!builder.snapshotVersionSet) throw new IllegalArgumentException("snapshot_version is required");
        this.snapshotVersion = builder.snapshotVersion;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public boolean done() { return done; }
    public UInt64 markerEpoch() { return markerEpoch; }
    public Field<UInt64> nextBefore() { return nextBefore; }
    public List<TerminalHistoryPage> pages() { return pages; }
    public int snapshotVersion() { return snapshotVersion; }
    public UInt64 surface() { return surface; }

    public static TerminalHistoryPagesResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalHistoryPagesResult");
        Builder builder = builder();
        Object rawDone = Wire.required(object, "done");
        builder.done(Wire.bool(rawDone, "TerminalHistoryPagesResult.done"));
        Object rawMarkerEpoch = Wire.required(object, "marker_epoch");
        builder.markerEpoch(Wire.uint64(rawMarkerEpoch, "TerminalHistoryPagesResult.marker_epoch"));
        Object rawNextBefore = Wire.optional(object, "next_before");
        if (!Wire.isMissing(rawNextBefore)) {
            builder.nextBefore(rawNextBefore == null ? null : Wire.uint64(rawNextBefore, "TerminalHistoryPagesResult.next_before"));
        }
        Object rawPages = Wire.required(object, "pages");
        builder.pages(Wire.array(rawPages, "TerminalHistoryPagesResult.pages", item -> TerminalHistoryPage.fromWire(item)));
        Object rawSnapshotVersion = Wire.required(object, "snapshot_version");
        builder.snapshotVersion(Wire.uint16(rawSnapshotVersion, "TerminalHistoryPagesResult.snapshot_version"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalHistoryPagesResult.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "done", done);
        Wire.put(object, "marker_epoch", markerEpoch);
        Wire.put(object, "next_before", nextBefore);
        Wire.put(object, "pages", pages);
        Wire.put(object, "snapshot_version", snapshotVersion);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalHistoryPagesResult that)) return false;
        return Objects.equals(done, that.done) && Objects.equals(markerEpoch, that.markerEpoch) && Objects.equals(nextBefore, that.nextBefore) && Objects.equals(pages, that.pages) && Objects.equals(snapshotVersion, that.snapshotVersion) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(done, markerEpoch, nextBefore, pages, snapshotVersion, surface); }

    @Override
    public String toString() { return "TerminalHistoryPagesResult" + toWire(); }

    public static final class Builder {
        private Boolean done;
        private boolean doneSet;
        private UInt64 markerEpoch;
        private boolean markerEpochSet;
        private Field<UInt64> nextBefore = Field.omitted();
        private List<TerminalHistoryPage> pages;
        private boolean pagesSet;
        private Integer snapshotVersion;
        private boolean snapshotVersionSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder done(boolean value) {
            this.done = value;
            this.doneSet = true;
            return this;
        }
        public Builder markerEpoch(UInt64 value) {
            this.markerEpoch = value;
            this.markerEpochSet = true;
            return this;
        }
        public Builder nextBefore(UInt64 value) {
            this.nextBefore = Field.ofNullable(value);
            return this;
        }
        public Builder pages(List<TerminalHistoryPage> value) {
            this.pages = value;
            this.pagesSet = true;
            return this;
        }
        public Builder snapshotVersion(int value) {
            this.snapshotVersion = value;
            this.snapshotVersionSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public TerminalHistoryPagesResult build() { return new TerminalHistoryPagesResult(this); }
    }
}

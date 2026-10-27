// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsPage implements WireValue {
    private final String cursor;
    private final List<FsEntry> entries;
    private final String listing;
    private final String revision;
    private final UInt64 total;

    private FsPage(Builder builder) {
        if (!builder.cursorSet) throw new IllegalArgumentException("cursor is required");
        this.cursor = builder.cursor;
        if (!builder.entriesSet) throw new IllegalArgumentException("entries is required");
        this.entries = List.copyOf(Wire.nonNull(builder.entries, "entries"));
        if (!builder.listingSet) throw new IllegalArgumentException("listing is required");
        this.listing = Wire.nonNull(builder.listing, "listing");
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.totalSet) throw new IllegalArgumentException("total is required");
        this.total = Wire.nonNull(builder.total, "total");
    }

    public static Builder builder() { return new Builder(); }

    public String cursor() { return cursor; }
    public List<FsEntry> entries() { return entries; }
    public String listing() { return listing; }
    public String revision() { return revision; }
    public UInt64 total() { return total; }

    public static FsPage fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsPage");
        Builder builder = builder();
        Object rawCursor = Wire.required(object, "cursor");
        builder.cursor(rawCursor == null ? null : Wire.string(rawCursor, "FsPage.cursor"));
        Object rawEntries = Wire.required(object, "entries");
        builder.entries(Wire.array(rawEntries, "FsPage.entries", item -> FsEntry.fromWire(item)));
        Object rawListing = Wire.required(object, "listing");
        builder.listing(Wire.string(rawListing, "FsPage.listing"));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.string(rawRevision, "FsPage.revision"));
        Object rawTotal = Wire.required(object, "total");
        builder.total(Wire.uint64(rawTotal, "FsPage.total"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "entries", entries);
        Wire.put(object, "listing", listing);
        Wire.put(object, "revision", revision);
        Wire.put(object, "total", total);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsPage that)) return false;
        return Objects.equals(cursor, that.cursor) && Objects.equals(entries, that.entries) && Objects.equals(listing, that.listing) && Objects.equals(revision, that.revision) && Objects.equals(total, that.total);
    }

    @Override
    public int hashCode() { return Objects.hash(cursor, entries, listing, revision, total); }

    @Override
    public String toString() { return "FsPage" + toWire(); }

    public static final class Builder {
        private String cursor;
        private boolean cursorSet;
        private List<FsEntry> entries;
        private boolean entriesSet;
        private String listing;
        private boolean listingSet;
        private String revision;
        private boolean revisionSet;
        private UInt64 total;
        private boolean totalSet;

        public Builder cursor(String value) {
            this.cursor = value;
            this.cursorSet = true;
            return this;
        }
        public Builder entries(List<FsEntry> value) {
            this.entries = value;
            this.entriesSet = true;
            return this;
        }
        public Builder listing(String value) {
            this.listing = value;
            this.listingSet = true;
            return this;
        }
        public Builder revision(String value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = value;
            this.totalSet = true;
            return this;
        }
        public FsPage build() { return new FsPage(this); }
    }
}

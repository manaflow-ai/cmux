// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDisk implements WireValue {
    private final String error;
    private final List<ServerStatsDiskFile> files;
    private final boolean filesTruncated;
    private final UInt64 filesUnlisted;
    private final UInt64 freelistPages;
    private final ServerStatsDiskJournal journal;
    private final UInt64 pageCount;
    private final UInt64 pageSize;
    private final UInt64 registryBytes;
    private final ServerStatsDiskSegments segments;
    private final UInt64 shmBytes;
    private final UInt64 walBytes;

    private ServerStatsDisk(Builder builder) {
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = builder.error;
        if (!builder.filesSet) throw new IllegalArgumentException("files is required");
        this.files = List.copyOf(Wire.nonNull(builder.files, "files"));
        if (!builder.filesTruncatedSet) throw new IllegalArgumentException("files_truncated is required");
        this.filesTruncated = builder.filesTruncated;
        if (!builder.filesUnlistedSet) throw new IllegalArgumentException("files_unlisted is required");
        this.filesUnlisted = Wire.nonNull(builder.filesUnlisted, "files_unlisted");
        if (!builder.freelistPagesSet) throw new IllegalArgumentException("freelist_pages is required");
        this.freelistPages = Wire.nonNull(builder.freelistPages, "freelist_pages");
        if (!builder.journalSet) throw new IllegalArgumentException("journal is required");
        this.journal = builder.journal;
        if (!builder.pageCountSet) throw new IllegalArgumentException("page_count is required");
        this.pageCount = Wire.nonNull(builder.pageCount, "page_count");
        if (!builder.pageSizeSet) throw new IllegalArgumentException("page_size is required");
        this.pageSize = Wire.nonNull(builder.pageSize, "page_size");
        if (!builder.registryBytesSet) throw new IllegalArgumentException("registry_bytes is required");
        this.registryBytes = Wire.nonNull(builder.registryBytes, "registry_bytes");
        if (!builder.segmentsSet) throw new IllegalArgumentException("segments is required");
        this.segments = builder.segments;
        if (!builder.shmBytesSet) throw new IllegalArgumentException("shm_bytes is required");
        this.shmBytes = Wire.nonNull(builder.shmBytes, "shm_bytes");
        if (!builder.walBytesSet) throw new IllegalArgumentException("wal_bytes is required");
        this.walBytes = Wire.nonNull(builder.walBytes, "wal_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public String error() { return error; }
    public List<ServerStatsDiskFile> files() { return files; }
    public boolean filesTruncated() { return filesTruncated; }
    public UInt64 filesUnlisted() { return filesUnlisted; }
    public UInt64 freelistPages() { return freelistPages; }
    public ServerStatsDiskJournal journal() { return journal; }
    public UInt64 pageCount() { return pageCount; }
    public UInt64 pageSize() { return pageSize; }
    public UInt64 registryBytes() { return registryBytes; }
    public ServerStatsDiskSegments segments() { return segments; }
    public UInt64 shmBytes() { return shmBytes; }
    public UInt64 walBytes() { return walBytes; }

    public static ServerStatsDisk fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDisk");
        Builder builder = builder();
        Object rawError = Wire.required(object, "error");
        builder.error(rawError == null ? null : Wire.string(rawError, "ServerStatsDisk.error"));
        Object rawFiles = Wire.required(object, "files");
        builder.files(Wire.array(rawFiles, "ServerStatsDisk.files", item -> ServerStatsDiskFile.fromWire(item)));
        Object rawFilesTruncated = Wire.required(object, "files_truncated");
        builder.filesTruncated(Wire.bool(rawFilesTruncated, "ServerStatsDisk.files_truncated"));
        Object rawFilesUnlisted = Wire.required(object, "files_unlisted");
        builder.filesUnlisted(Wire.uint64(rawFilesUnlisted, "ServerStatsDisk.files_unlisted"));
        Object rawFreelistPages = Wire.required(object, "freelist_pages");
        builder.freelistPages(Wire.uint64(rawFreelistPages, "ServerStatsDisk.freelist_pages"));
        Object rawJournal = Wire.required(object, "journal");
        builder.journal(rawJournal == null ? null : ServerStatsDiskJournal.fromWire(rawJournal));
        Object rawPageCount = Wire.required(object, "page_count");
        builder.pageCount(Wire.uint64(rawPageCount, "ServerStatsDisk.page_count"));
        Object rawPageSize = Wire.required(object, "page_size");
        builder.pageSize(Wire.uint64(rawPageSize, "ServerStatsDisk.page_size"));
        Object rawRegistryBytes = Wire.required(object, "registry_bytes");
        builder.registryBytes(Wire.uint64(rawRegistryBytes, "ServerStatsDisk.registry_bytes"));
        Object rawSegments = Wire.required(object, "segments");
        builder.segments(rawSegments == null ? null : ServerStatsDiskSegments.fromWire(rawSegments));
        Object rawShmBytes = Wire.required(object, "shm_bytes");
        builder.shmBytes(Wire.uint64(rawShmBytes, "ServerStatsDisk.shm_bytes"));
        Object rawWalBytes = Wire.required(object, "wal_bytes");
        builder.walBytes(Wire.uint64(rawWalBytes, "ServerStatsDisk.wal_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "error", error);
        Wire.put(object, "files", files);
        Wire.put(object, "files_truncated", filesTruncated);
        Wire.put(object, "files_unlisted", filesUnlisted);
        Wire.put(object, "freelist_pages", freelistPages);
        Wire.put(object, "journal", journal);
        Wire.put(object, "page_count", pageCount);
        Wire.put(object, "page_size", pageSize);
        Wire.put(object, "registry_bytes", registryBytes);
        Wire.put(object, "segments", segments);
        Wire.put(object, "shm_bytes", shmBytes);
        Wire.put(object, "wal_bytes", walBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDisk that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(files, that.files) && Objects.equals(filesTruncated, that.filesTruncated) && Objects.equals(filesUnlisted, that.filesUnlisted) && Objects.equals(freelistPages, that.freelistPages) && Objects.equals(journal, that.journal) && Objects.equals(pageCount, that.pageCount) && Objects.equals(pageSize, that.pageSize) && Objects.equals(registryBytes, that.registryBytes) && Objects.equals(segments, that.segments) && Objects.equals(shmBytes, that.shmBytes) && Objects.equals(walBytes, that.walBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(error, files, filesTruncated, filesUnlisted, freelistPages, journal, pageCount, pageSize, registryBytes, segments, shmBytes, walBytes); }

    @Override
    public String toString() { return "ServerStatsDisk" + toWire(); }

    public static final class Builder {
        private String error;
        private boolean errorSet;
        private List<ServerStatsDiskFile> files;
        private boolean filesSet;
        private Boolean filesTruncated;
        private boolean filesTruncatedSet;
        private UInt64 filesUnlisted;
        private boolean filesUnlistedSet;
        private UInt64 freelistPages;
        private boolean freelistPagesSet;
        private ServerStatsDiskJournal journal;
        private boolean journalSet;
        private UInt64 pageCount;
        private boolean pageCountSet;
        private UInt64 pageSize;
        private boolean pageSizeSet;
        private UInt64 registryBytes;
        private boolean registryBytesSet;
        private ServerStatsDiskSegments segments;
        private boolean segmentsSet;
        private UInt64 shmBytes;
        private boolean shmBytesSet;
        private UInt64 walBytes;
        private boolean walBytesSet;

        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder files(List<ServerStatsDiskFile> value) {
            this.files = value;
            this.filesSet = true;
            return this;
        }
        public Builder filesTruncated(boolean value) {
            this.filesTruncated = value;
            this.filesTruncatedSet = true;
            return this;
        }
        public Builder filesUnlisted(UInt64 value) {
            this.filesUnlisted = value;
            this.filesUnlistedSet = true;
            return this;
        }
        public Builder freelistPages(UInt64 value) {
            this.freelistPages = value;
            this.freelistPagesSet = true;
            return this;
        }
        public Builder journal(ServerStatsDiskJournal value) {
            this.journal = value;
            this.journalSet = true;
            return this;
        }
        public Builder pageCount(UInt64 value) {
            this.pageCount = value;
            this.pageCountSet = true;
            return this;
        }
        public Builder pageSize(UInt64 value) {
            this.pageSize = value;
            this.pageSizeSet = true;
            return this;
        }
        public Builder registryBytes(UInt64 value) {
            this.registryBytes = value;
            this.registryBytesSet = true;
            return this;
        }
        public Builder segments(ServerStatsDiskSegments value) {
            this.segments = value;
            this.segmentsSet = true;
            return this;
        }
        public Builder shmBytes(UInt64 value) {
            this.shmBytes = value;
            this.shmBytesSet = true;
            return this;
        }
        public Builder walBytes(UInt64 value) {
            this.walBytes = value;
            this.walBytesSet = true;
            return this;
        }
        public ServerStatsDisk build() { return new ServerStatsDisk(this); }
    }
}

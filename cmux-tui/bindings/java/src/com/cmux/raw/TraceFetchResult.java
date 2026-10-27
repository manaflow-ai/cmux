// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TraceFetchResult implements WireValue {
    private final String data;
    private final boolean done;
    private final UInt64 fetchId;
    private final UInt64 offset;
    private final long pid;
    private final TraceFetchResultRole role;
    private final UInt64 totalBytes;

    private TraceFetchResult(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.doneSet) throw new IllegalArgumentException("done is required");
        this.done = builder.done;
        if (!builder.fetchIdSet) throw new IllegalArgumentException("fetch_id is required");
        this.fetchId = Wire.nonNull(builder.fetchId, "fetch_id");
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
        if (!builder.roleSet) throw new IllegalArgumentException("role is required");
        this.role = Wire.nonNull(builder.role, "role");
        if (!builder.totalBytesSet) throw new IllegalArgumentException("total_bytes is required");
        this.totalBytes = Wire.nonNull(builder.totalBytes, "total_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public String data() { return data; }
    public boolean done() { return done; }
    public UInt64 fetchId() { return fetchId; }
    public UInt64 offset() { return offset; }
    public long pid() { return pid; }
    public TraceFetchResultRole role() { return role; }
    public UInt64 totalBytes() { return totalBytes; }

    public static TraceFetchResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TraceFetchResult");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.string(rawData, "TraceFetchResult.data"));
        Object rawDone = Wire.required(object, "done");
        builder.done(Wire.bool(rawDone, "TraceFetchResult.done"));
        Object rawFetchId = Wire.required(object, "fetch_id");
        builder.fetchId(Wire.uint64(rawFetchId, "TraceFetchResult.fetch_id"));
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "TraceFetchResult.offset"));
        Object rawPid = Wire.required(object, "pid");
        builder.pid(Wire.uint32(rawPid, "TraceFetchResult.pid"));
        Object rawRole = Wire.required(object, "role");
        builder.role(TraceFetchResultRole.fromWire(rawRole));
        Object rawTotalBytes = Wire.required(object, "total_bytes");
        builder.totalBytes(Wire.uint64(rawTotalBytes, "TraceFetchResult.total_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "done", done);
        Wire.put(object, "fetch_id", fetchId);
        Wire.put(object, "offset", offset);
        Wire.put(object, "pid", pid);
        Wire.put(object, "role", role);
        Wire.put(object, "total_bytes", totalBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TraceFetchResult that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(done, that.done) && Objects.equals(fetchId, that.fetchId) && Objects.equals(offset, that.offset) && Objects.equals(pid, that.pid) && Objects.equals(role, that.role) && Objects.equals(totalBytes, that.totalBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(data, done, fetchId, offset, pid, role, totalBytes); }

    @Override
    public String toString() { return "TraceFetchResult" + toWire(); }

    public static final class Builder {
        private String data;
        private boolean dataSet;
        private Boolean done;
        private boolean doneSet;
        private UInt64 fetchId;
        private boolean fetchIdSet;
        private UInt64 offset;
        private boolean offsetSet;
        private Long pid;
        private boolean pidSet;
        private TraceFetchResultRole role;
        private boolean roleSet;
        private UInt64 totalBytes;
        private boolean totalBytesSet;

        public Builder data(String value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder done(boolean value) {
            this.done = value;
            this.doneSet = true;
            return this;
        }
        public Builder fetchId(UInt64 value) {
            this.fetchId = value;
            this.fetchIdSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public Builder pid(long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public Builder role(TraceFetchResultRole value) {
            this.role = value;
            this.roleSet = true;
            return this;
        }
        public Builder totalBytes(UInt64 value) {
            this.totalBytes = value;
            this.totalBytesSet = true;
            return this;
        }
        public TraceFetchResult build() { return new TraceFetchResult(this); }
    }
}

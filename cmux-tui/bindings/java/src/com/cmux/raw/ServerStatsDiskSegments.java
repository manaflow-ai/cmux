// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskSegments implements WireValue {
    private final List<ServerStatsDiskSegmentCodec> byCodec;
    private final UInt64 compressedBytes;
    private final List<ServerStatsDiskSegmentKind> kinds;
    private final UInt64 records;
    private final UInt64 segments;
    private final UInt64 uncompressedBytes;

    private ServerStatsDiskSegments(Builder builder) {
        if (!builder.byCodecSet) throw new IllegalArgumentException("by_codec is required");
        this.byCodec = List.copyOf(Wire.nonNull(builder.byCodec, "by_codec"));
        if (!builder.compressedBytesSet) throw new IllegalArgumentException("compressed_bytes is required");
        this.compressedBytes = Wire.nonNull(builder.compressedBytes, "compressed_bytes");
        if (!builder.kindsSet) throw new IllegalArgumentException("kinds is required");
        this.kinds = List.copyOf(Wire.nonNull(builder.kinds, "kinds"));
        if (!builder.recordsSet) throw new IllegalArgumentException("records is required");
        this.records = Wire.nonNull(builder.records, "records");
        if (!builder.segmentsSet) throw new IllegalArgumentException("segments is required");
        this.segments = Wire.nonNull(builder.segments, "segments");
        if (!builder.uncompressedBytesSet) throw new IllegalArgumentException("uncompressed_bytes is required");
        this.uncompressedBytes = Wire.nonNull(builder.uncompressedBytes, "uncompressed_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public List<ServerStatsDiskSegmentCodec> byCodec() { return byCodec; }
    public UInt64 compressedBytes() { return compressedBytes; }
    public List<ServerStatsDiskSegmentKind> kinds() { return kinds; }
    public UInt64 records() { return records; }
    public UInt64 segments() { return segments; }
    public UInt64 uncompressedBytes() { return uncompressedBytes; }

    public static ServerStatsDiskSegments fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskSegments");
        Builder builder = builder();
        Object rawByCodec = Wire.required(object, "by_codec");
        builder.byCodec(Wire.array(rawByCodec, "ServerStatsDiskSegments.by_codec", item -> ServerStatsDiskSegmentCodec.fromWire(item)));
        Object rawCompressedBytes = Wire.required(object, "compressed_bytes");
        builder.compressedBytes(Wire.uint64(rawCompressedBytes, "ServerStatsDiskSegments.compressed_bytes"));
        Object rawKinds = Wire.required(object, "kinds");
        builder.kinds(Wire.array(rawKinds, "ServerStatsDiskSegments.kinds", item -> ServerStatsDiskSegmentKind.fromWire(item)));
        Object rawRecords = Wire.required(object, "records");
        builder.records(Wire.uint64(rawRecords, "ServerStatsDiskSegments.records"));
        Object rawSegments = Wire.required(object, "segments");
        builder.segments(Wire.uint64(rawSegments, "ServerStatsDiskSegments.segments"));
        Object rawUncompressedBytes = Wire.required(object, "uncompressed_bytes");
        builder.uncompressedBytes(Wire.uint64(rawUncompressedBytes, "ServerStatsDiskSegments.uncompressed_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "by_codec", byCodec);
        Wire.put(object, "compressed_bytes", compressedBytes);
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "records", records);
        Wire.put(object, "segments", segments);
        Wire.put(object, "uncompressed_bytes", uncompressedBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskSegments that)) return false;
        return Objects.equals(byCodec, that.byCodec) && Objects.equals(compressedBytes, that.compressedBytes) && Objects.equals(kinds, that.kinds) && Objects.equals(records, that.records) && Objects.equals(segments, that.segments) && Objects.equals(uncompressedBytes, that.uncompressedBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(byCodec, compressedBytes, kinds, records, segments, uncompressedBytes); }

    @Override
    public String toString() { return "ServerStatsDiskSegments" + toWire(); }

    public static final class Builder {
        private List<ServerStatsDiskSegmentCodec> byCodec;
        private boolean byCodecSet;
        private UInt64 compressedBytes;
        private boolean compressedBytesSet;
        private List<ServerStatsDiskSegmentKind> kinds;
        private boolean kindsSet;
        private UInt64 records;
        private boolean recordsSet;
        private UInt64 segments;
        private boolean segmentsSet;
        private UInt64 uncompressedBytes;
        private boolean uncompressedBytesSet;

        public Builder byCodec(List<ServerStatsDiskSegmentCodec> value) {
            this.byCodec = value;
            this.byCodecSet = true;
            return this;
        }
        public Builder compressedBytes(UInt64 value) {
            this.compressedBytes = value;
            this.compressedBytesSet = true;
            return this;
        }
        public Builder kinds(List<ServerStatsDiskSegmentKind> value) {
            this.kinds = value;
            this.kindsSet = true;
            return this;
        }
        public Builder records(UInt64 value) {
            this.records = value;
            this.recordsSet = true;
            return this;
        }
        public Builder segments(UInt64 value) {
            this.segments = value;
            this.segmentsSet = true;
            return this;
        }
        public Builder uncompressedBytes(UInt64 value) {
            this.uncompressedBytes = value;
            this.uncompressedBytesSet = true;
            return this;
        }
        public ServerStatsDiskSegments build() { return new ServerStatsDiskSegments(this); }
    }
}

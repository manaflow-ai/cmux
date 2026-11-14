// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskSegmentCodec implements WireValue {
    private final String codec;
    private final UInt64 compressedBytes;
    private final UInt64 records;
    private final UInt64 segments;
    private final UInt64 uncompressedBytes;

    private ServerStatsDiskSegmentCodec(Builder builder) {
        if (!builder.codecSet) throw new IllegalArgumentException("codec is required");
        this.codec = Wire.nonNull(builder.codec, "codec");
        if (!builder.compressedBytesSet) throw new IllegalArgumentException("compressed_bytes is required");
        this.compressedBytes = Wire.nonNull(builder.compressedBytes, "compressed_bytes");
        if (!builder.recordsSet) throw new IllegalArgumentException("records is required");
        this.records = Wire.nonNull(builder.records, "records");
        if (!builder.segmentsSet) throw new IllegalArgumentException("segments is required");
        this.segments = Wire.nonNull(builder.segments, "segments");
        if (!builder.uncompressedBytesSet) throw new IllegalArgumentException("uncompressed_bytes is required");
        this.uncompressedBytes = Wire.nonNull(builder.uncompressedBytes, "uncompressed_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public String codec() { return codec; }
    public UInt64 compressedBytes() { return compressedBytes; }
    public UInt64 records() { return records; }
    public UInt64 segments() { return segments; }
    public UInt64 uncompressedBytes() { return uncompressedBytes; }

    public static ServerStatsDiskSegmentCodec fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskSegmentCodec");
        Builder builder = builder();
        Object rawCodec = Wire.required(object, "codec");
        builder.codec(Wire.string(rawCodec, "ServerStatsDiskSegmentCodec.codec"));
        Object rawCompressedBytes = Wire.required(object, "compressed_bytes");
        builder.compressedBytes(Wire.uint64(rawCompressedBytes, "ServerStatsDiskSegmentCodec.compressed_bytes"));
        Object rawRecords = Wire.required(object, "records");
        builder.records(Wire.uint64(rawRecords, "ServerStatsDiskSegmentCodec.records"));
        Object rawSegments = Wire.required(object, "segments");
        builder.segments(Wire.uint64(rawSegments, "ServerStatsDiskSegmentCodec.segments"));
        Object rawUncompressedBytes = Wire.required(object, "uncompressed_bytes");
        builder.uncompressedBytes(Wire.uint64(rawUncompressedBytes, "ServerStatsDiskSegmentCodec.uncompressed_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "codec", codec);
        Wire.put(object, "compressed_bytes", compressedBytes);
        Wire.put(object, "records", records);
        Wire.put(object, "segments", segments);
        Wire.put(object, "uncompressed_bytes", uncompressedBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskSegmentCodec that)) return false;
        return Objects.equals(codec, that.codec) && Objects.equals(compressedBytes, that.compressedBytes) && Objects.equals(records, that.records) && Objects.equals(segments, that.segments) && Objects.equals(uncompressedBytes, that.uncompressedBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(codec, compressedBytes, records, segments, uncompressedBytes); }

    @Override
    public String toString() { return "ServerStatsDiskSegmentCodec" + toWire(); }

    public static final class Builder {
        private String codec;
        private boolean codecSet;
        private UInt64 compressedBytes;
        private boolean compressedBytesSet;
        private UInt64 records;
        private boolean recordsSet;
        private UInt64 segments;
        private boolean segmentsSet;
        private UInt64 uncompressedBytes;
        private boolean uncompressedBytesSet;

        public Builder codec(String value) {
            this.codec = value;
            this.codecSet = true;
            return this;
        }
        public Builder compressedBytes(UInt64 value) {
            this.compressedBytes = value;
            this.compressedBytesSet = true;
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
        public ServerStatsDiskSegmentCodec build() { return new ServerStatsDiskSegmentCodec(this); }
    }
}

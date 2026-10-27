// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsReadResultBase64 implements WireValue, FsReadResult {
    private final Bytes bytesBase64;
    private final UInt64 size;
    private final boolean truncated;

    private FsReadResultBase64(Builder builder) {
        if (!builder.bytesBase64Set) throw new IllegalArgumentException("bytes_base64 is required");
        this.bytesBase64 = Wire.nonNull(builder.bytesBase64, "bytes_base64");
        if (!builder.sizeSet) throw new IllegalArgumentException("size is required");
        this.size = Wire.nonNull(builder.size, "size");
        if (!builder.truncatedSet) throw new IllegalArgumentException("truncated is required");
        this.truncated = builder.truncated;
    }

    public static Builder builder() { return new Builder(); }

    public Bytes bytesBase64() { return bytesBase64; }
    public String encoding() { return "base64"; }
    public UInt64 size() { return size; }
    public boolean truncated() { return truncated; }

    public static FsReadResultBase64 fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsReadResultBase64");
        Builder builder = builder();
        Object rawBytesBase64 = Wire.required(object, "bytes_base64");
        builder.bytesBase64(Wire.bytes(rawBytesBase64, "FsReadResultBase64.bytes_base64"));
        Object rawEncoding = Wire.required(object, "encoding");
        ProtocolSupport.literal(rawEncoding, "base64", "FsReadResultBase64.encoding");
        Object rawSize = Wire.required(object, "size");
        builder.size(Wire.uint64(rawSize, "FsReadResultBase64.size"));
        Object rawTruncated = Wire.required(object, "truncated");
        builder.truncated(Wire.bool(rawTruncated, "FsReadResultBase64.truncated"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes_base64", bytesBase64);
        Wire.put(object, "encoding", "base64");
        Wire.put(object, "size", size);
        Wire.put(object, "truncated", truncated);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsReadResultBase64 that)) return false;
        return Objects.equals(bytesBase64, that.bytesBase64) && Objects.equals(size, that.size) && Objects.equals(truncated, that.truncated);
    }

    @Override
    public int hashCode() { return Objects.hash(bytesBase64, size, truncated); }

    @Override
    public String toString() { return "FsReadResultBase64" + toWire(); }

    public static final class Builder {
        private Bytes bytesBase64;
        private boolean bytesBase64Set;
        private UInt64 size;
        private boolean sizeSet;
        private Boolean truncated;
        private boolean truncatedSet;

        public Builder bytesBase64(Bytes value) {
            this.bytesBase64 = value;
            this.bytesBase64Set = true;
            return this;
        }
        public Builder size(UInt64 value) {
            this.size = value;
            this.sizeSet = true;
            return this;
        }
        public Builder truncated(boolean value) {
            this.truncated = value;
            this.truncatedSet = true;
            return this;
        }
        public FsReadResultBase64 build() { return new FsReadResultBase64(this); }
    }
}

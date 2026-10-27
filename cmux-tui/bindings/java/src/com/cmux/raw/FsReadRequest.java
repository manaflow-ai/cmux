// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable fs.read request. Protocol v12; authority: control. */
public final class FsReadRequest implements WireValue {
    private final UInt64 maxBytes;
    private final Field<UInt64> offset;
    private final String path;

    private FsReadRequest(Builder builder) {
        if (!builder.maxBytesSet) throw new IllegalArgumentException("max_bytes is required");
        this.maxBytes = Wire.nonNull(builder.maxBytes, "max_bytes");
        this.offset = builder.offset;
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 maxBytes() { return maxBytes; }
    public Field<UInt64> offset() { return offset; }
    public String path() { return path; }

    public static FsReadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsReadRequest");
        Builder builder = builder();
        Object rawMaxBytes = Wire.required(object, "max_bytes");
        builder.maxBytes(Wire.uint64(rawMaxBytes, "FsReadRequest.max_bytes"));
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(Wire.uint64(rawOffset, "FsReadRequest.offset"));
        }
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "FsReadRequest.path"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "max_bytes", maxBytes);
        Wire.put(object, "offset", offset);
        Wire.put(object, "path", path);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsReadRequest that)) return false;
        return Objects.equals(maxBytes, that.maxBytes) && Objects.equals(offset, that.offset) && Objects.equals(path, that.path);
    }

    @Override
    public int hashCode() { return Objects.hash(maxBytes, offset, path); }

    @Override
    public String toString() { return "FsReadRequest" + toWire(); }

    public static final class Builder {
        private UInt64 maxBytes;
        private boolean maxBytesSet;
        private Field<UInt64> offset = Field.omitted();
        private String path;
        private boolean pathSet;

        public Builder maxBytes(UInt64 value) {
            this.maxBytes = value;
            this.maxBytesSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = Field.of(value);
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public FsReadRequest build() { return new FsReadRequest(this); }
    }
}

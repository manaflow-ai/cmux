// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable loopback-credit request. Protocol v12; authority: local-admin. */
public final class LoopbackCreditRequest implements WireValue {
    private final UInt64 bytes;
    private final UInt64 stream;

    private LoopbackCreditRequest(Builder builder) {
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bytes() { return bytes; }
    public UInt64 stream() { return stream; }

    public static LoopbackCreditRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackCreditRequest");
        Builder builder = builder();
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "LoopbackCreditRequest.bytes"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackCreditRequest.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackCreditRequest that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, stream); }

    @Override
    public String toString() { return "LoopbackCreditRequest" + toWire(); }

    public static final class Builder {
        private UInt64 bytes;
        private boolean bytesSet;
        private UInt64 stream;
        private boolean streamSet;

        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public LoopbackCreditRequest build() { return new LoopbackCreditRequest(this); }
    }
}

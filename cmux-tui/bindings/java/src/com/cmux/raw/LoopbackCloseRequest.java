// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable loopback-close request. Protocol v12; authority: local-admin. */
public final class LoopbackCloseRequest implements WireValue {
    private final UInt64 stream;

    private LoopbackCloseRequest(Builder builder) {
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 stream() { return stream; }

    public static LoopbackCloseRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackCloseRequest");
        Builder builder = builder();
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackCloseRequest.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackCloseRequest that)) return false;
        return Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(stream); }

    @Override
    public String toString() { return "LoopbackCloseRequest" + toWire(); }

    public static final class Builder {
        private UInt64 stream;
        private boolean streamSet;

        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public LoopbackCloseRequest build() { return new LoopbackCloseRequest(this); }
    }
}

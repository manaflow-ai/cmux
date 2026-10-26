// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cancel-stream request. Protocol v12; authority: frontend. */
public final class CancelStreamRequest implements WireValue {
    private final int stream;

    private CancelStreamRequest(Builder builder) {
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public int stream() { return stream; }

    public static CancelStreamRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CancelStreamRequest");
        Builder builder = builder();
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "CancelStreamRequest.stream"));
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
        if (!(other instanceof CancelStreamRequest that)) return false;
        return Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(stream); }

    @Override
    public String toString() { return "CancelStreamRequest" + toWire(); }

    public static final class Builder {
        private Integer stream;
        private boolean streamSet;

        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public CancelStreamRequest build() { return new CancelStreamRequest(this); }
    }
}

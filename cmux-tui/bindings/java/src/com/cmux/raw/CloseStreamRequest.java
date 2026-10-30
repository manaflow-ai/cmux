// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-stream request. Protocol v12; authority: local-admin. */
public final class CloseStreamRequest implements WireValue {
    private final int stream;

    private CloseStreamRequest(Builder builder) {
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public int stream() { return stream; }

    public static CloseStreamRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseStreamRequest");
        Builder builder = builder();
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "CloseStreamRequest.stream"));
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
        if (!(other instanceof CloseStreamRequest that)) return false;
        return Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(stream); }

    @Override
    public String toString() { return "CloseStreamRequest" + toWire(); }

    public static final class Builder {
        private Integer stream;
        private boolean streamSet;

        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public CloseStreamRequest build() { return new CloseStreamRequest(this); }
    }
}

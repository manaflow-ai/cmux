// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CloseStreamResult implements WireValue {
    private final boolean closed;
    private final int stream;

    private CloseStreamResult(Builder builder) {
        if (!builder.closedSet) throw new IllegalArgumentException("closed is required");
        this.closed = builder.closed;
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public boolean closed() { return closed; }
    public int stream() { return stream; }

    public static CloseStreamResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseStreamResult");
        Builder builder = builder();
        Object rawClosed = Wire.required(object, "closed");
        builder.closed(Wire.bool(rawClosed, "CloseStreamResult.closed"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "CloseStreamResult.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "closed", closed);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseStreamResult that)) return false;
        return Objects.equals(closed, that.closed) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(closed, stream); }

    @Override
    public String toString() { return "CloseStreamResult" + toWire(); }

    public static final class Builder {
        private Boolean closed;
        private boolean closedSet;
        private Integer stream;
        private boolean streamSet;

        public Builder closed(boolean value) {
            this.closed = value;
            this.closedSet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public CloseStreamResult build() { return new CloseStreamResult(this); }
    }
}

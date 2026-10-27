// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable loopback-closed event. Protocol v12; streams: control. */
public final class LoopbackClosedEvent implements WireValue, ProtocolEvent {
    private final Field<String> error;
    private final UInt64 stream;

    private LoopbackClosedEvent(Builder builder) {
        this.error = builder.error;
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> error() { return error; }
    public UInt64 stream() { return stream; }
    @Override public String event() { return "loopback-closed"; }

    public static LoopbackClosedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackClosedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "loopback-closed", "LoopbackClosedEvent.event");
        Object rawError = Wire.optional(object, "error");
        if (!Wire.isMissing(rawError)) {
            builder.error(Wire.string(rawError, "LoopbackClosedEvent.error"));
        }
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackClosedEvent.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "loopback-closed");
        Wire.put(object, "error", error);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackClosedEvent that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(error, stream); }

    @Override
    public String toString() { return "LoopbackClosedEvent" + toWire(); }

    public static final class Builder {
        private Field<String> error = Field.omitted();
        private UInt64 stream;
        private boolean streamSet;

        public Builder error(String value) {
            this.error = Field.of(value);
            return this;
        }
        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public LoopbackClosedEvent build() { return new LoopbackClosedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable loopback-eof event. Protocol v12; streams: control. */
public final class LoopbackEofEvent implements WireValue, ProtocolEvent {
    private final UInt64 stream;

    private LoopbackEofEvent(Builder builder) {
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 stream() { return stream; }
    @Override public String event() { return "loopback-eof"; }

    public static LoopbackEofEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackEofEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "loopback-eof", "LoopbackEofEvent.event");
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackEofEvent.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "loopback-eof");
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackEofEvent that)) return false;
        return Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(stream); }

    @Override
    public String toString() { return "LoopbackEofEvent" + toWire(); }

    public static final class Builder {
        private UInt64 stream;
        private boolean streamSet;

        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public LoopbackEofEvent build() { return new LoopbackEofEvent(this); }
    }
}

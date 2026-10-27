// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable loopback-data event. Protocol v12; streams: control. */
public final class LoopbackDataEvent implements WireValue, ProtocolEvent {
    private final String data;
    private final UInt64 stream;

    private LoopbackDataEvent(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
    }

    public static Builder builder() { return new Builder(); }

    public String data() { return data; }
    public UInt64 stream() { return stream; }
    @Override public String event() { return "loopback-data"; }

    public static LoopbackDataEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackDataEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "loopback-data", "LoopbackDataEvent.event");
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.string(rawData, "LoopbackDataEvent.data"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackDataEvent.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "loopback-data");
        Wire.put(object, "data", data);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackDataEvent that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(data, stream); }

    @Override
    public String toString() { return "LoopbackDataEvent" + toWire(); }

    public static final class Builder {
        private String data;
        private boolean dataSet;
        private UInt64 stream;
        private boolean streamSet;

        public Builder data(String value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public LoopbackDataEvent build() { return new LoopbackDataEvent(this); }
    }
}

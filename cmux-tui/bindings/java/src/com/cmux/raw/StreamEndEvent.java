// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable stream-end event. Protocol v12; streams: attach-byte, attach-render, attach-browser. */
public final class StreamEndEvent implements WireValue, BrowserAttachEvent, ByteAttachEvent, ProtocolEvent, RenderAttachEvent {
    private final StreamEndEventReason reason;
    private final int stream;

    private StreamEndEvent(Builder builder) {
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public StreamEndEventReason reason() { return reason; }
    public int stream() { return stream; }
    @Override public String event() { return "stream-end"; }

    public static StreamEndEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "StreamEndEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "stream-end", "StreamEndEvent.event");
        Object rawReason = Wire.required(object, "reason");
        builder.reason(StreamEndEventReason.fromWire(rawReason));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "StreamEndEvent.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "stream-end");
        Wire.put(object, "reason", reason);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof StreamEndEvent that)) return false;
        return Objects.equals(reason, that.reason) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(reason, stream); }

    @Override
    public String toString() { return "StreamEndEvent" + toWire(); }

    public static final class Builder {
        private StreamEndEventReason reason;
        private boolean reasonSet;
        private Integer stream;
        private boolean streamSet;

        public Builder reason(StreamEndEventReason value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public StreamEndEvent build() { return new StreamEndEvent(this); }
    }
}

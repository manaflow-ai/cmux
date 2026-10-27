// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable input-failed event. Protocol v12; streams: attach-byte. */
public final class InputFailedEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final UInt64 bytes;
    private final InputFailedEventReason reason;
    /** The attach stream the INPUT frame named; the stream's tag, as on every item of an attach stream. */
    private final int stream;

    private InputFailedEvent(Builder builder) {
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bytes() { return bytes; }
    public InputFailedEventReason reason() { return reason; }
    public int stream() { return stream; }
    @Override public String event() { return "input-failed"; }

    public static InputFailedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "InputFailedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "input-failed", "InputFailedEvent.event");
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "InputFailedEvent.bytes"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(InputFailedEventReason.fromWire(rawReason));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "InputFailedEvent.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "input-failed");
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "reason", reason);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof InputFailedEvent that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(reason, that.reason) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, reason, stream); }

    @Override
    public String toString() { return "InputFailedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 bytes;
        private boolean bytesSet;
        private InputFailedEventReason reason;
        private boolean reasonSet;
        private Integer stream;
        private boolean streamSet;

        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder reason(InputFailedEventReason value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public InputFailedEvent build() { return new InputFailedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable frame event. Protocol v6; streams: attach-browser. */
public final class FrameEvent implements WireValue, BrowserAttachEvent, ProtocolEvent {
    private final Bytes data;
    private final long height;
    private final UInt64 seq;
    private final UInt64 surface;
    private final long width;

    private FrameEvent(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = builder.height;
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Bytes data() { return data; }
    public long height() { return height; }
    public UInt64 seq() { return seq; }
    public UInt64 surface() { return surface; }
    public long width() { return width; }
    @Override public String event() { return "frame"; }

    public static FrameEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrameEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "frame", "FrameEvent.event");
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "FrameEvent.data"));
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint32(rawHeight, "FrameEvent.height"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "FrameEvent.seq"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "FrameEvent.surface"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.uint32(rawWidth, "FrameEvent.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "frame");
        Wire.put(object, "data", data);
        Wire.put(object, "height", height);
        Wire.put(object, "seq", seq);
        Wire.put(object, "surface", surface);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrameEvent that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(height, that.height) && Objects.equals(seq, that.seq) && Objects.equals(surface, that.surface) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(data, height, seq, surface, width); }

    @Override
    public String toString() { return "FrameEvent" + toWire(); }

    public static final class Builder {
        private Bytes data;
        private boolean dataSet;
        private Long height;
        private boolean heightSet;
        private UInt64 seq;
        private boolean seqSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Long width;
        private boolean widthSet;

        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder height(long value) {
            this.height = value;
            this.heightSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder width(long value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public FrameEvent build() { return new FrameEvent(this); }
    }
}

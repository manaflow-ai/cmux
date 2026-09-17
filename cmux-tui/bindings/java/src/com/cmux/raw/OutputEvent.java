// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable output event. Protocol v5; streams: attach-byte. */
public final class OutputEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final Field<TerminalColors> colors;
    private final Bytes data;
    private final UInt64 surface;

    private OutputEvent(Builder builder) {
        this.colors = builder.colors;
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<TerminalColors> colors() { return colors; }
    public Bytes data() { return data; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "output"; }

    public static OutputEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "OutputEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "output", "OutputEvent.event");
        Object rawColors = Wire.optional(object, "colors");
        if (!Wire.isMissing(rawColors)) {
            builder.colors(TerminalColors.fromWire(rawColors));
        }
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "OutputEvent.data"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "OutputEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "output");
        Wire.put(object, "colors", colors);
        Wire.put(object, "data", data);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof OutputEvent that)) return false;
        return Objects.equals(colors, that.colors) && Objects.equals(data, that.data) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(colors, data, surface); }

    @Override
    public String toString() { return "OutputEvent" + toWire(); }

    public static final class Builder {
        private Field<TerminalColors> colors = Field.omitted();
        private Bytes data;
        private boolean dataSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder colors(TerminalColors value) {
            this.colors = Field.of(value);
            return this;
        }
        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public OutputEvent build() { return new OutputEvent(this); }
    }
}

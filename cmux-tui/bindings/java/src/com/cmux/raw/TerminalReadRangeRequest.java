// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-read-range request. Protocol v12; authority: control. */
public final class TerminalReadRangeRequest implements WireValue {
    private final Field<String> format;
    private final RowMarkerPoint from;
    private final UInt64 markerEpoch;
    private final Field<UInt64> maxBytes;
    private final UInt64 surface;
    private final RowMarkerPoint to_;

    private TerminalReadRangeRequest(Builder builder) {
        this.format = builder.format;
        if (!builder.fromSet) throw new IllegalArgumentException("from is required");
        this.from = Wire.nonNull(builder.from, "from");
        if (!builder.markerEpochSet) throw new IllegalArgumentException("marker_epoch is required");
        this.markerEpoch = Wire.nonNull(builder.markerEpoch, "marker_epoch");
        this.maxBytes = builder.maxBytes;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.to_Set) throw new IllegalArgumentException("to is required");
        this.to_ = Wire.nonNull(builder.to_, "to");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> format() { return format; }
    public RowMarkerPoint from() { return from; }
    public UInt64 markerEpoch() { return markerEpoch; }
    public Field<UInt64> maxBytes() { return maxBytes; }
    public UInt64 surface() { return surface; }
    public RowMarkerPoint to_() { return to_; }

    public static TerminalReadRangeRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalReadRangeRequest");
        Builder builder = builder();
        Object rawFormat = Wire.optional(object, "format");
        if (!Wire.isMissing(rawFormat)) {
            builder.format(rawFormat == null ? null : Wire.string(rawFormat, "TerminalReadRangeRequest.format"));
        }
        Object rawFrom = Wire.required(object, "from");
        builder.from(RowMarkerPoint.fromWire(rawFrom));
        Object rawMarkerEpoch = Wire.required(object, "marker_epoch");
        builder.markerEpoch(Wire.uint64(rawMarkerEpoch, "TerminalReadRangeRequest.marker_epoch"));
        Object rawMaxBytes = Wire.optional(object, "max_bytes");
        if (!Wire.isMissing(rawMaxBytes)) {
            builder.maxBytes(rawMaxBytes == null ? null : Wire.uint64(rawMaxBytes, "TerminalReadRangeRequest.max_bytes"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalReadRangeRequest.surface"));
        Object rawTo = Wire.required(object, "to");
        builder.to_(RowMarkerPoint.fromWire(rawTo));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "format", format);
        Wire.put(object, "from", from);
        Wire.put(object, "marker_epoch", markerEpoch);
        Wire.put(object, "max_bytes", maxBytes);
        Wire.put(object, "surface", surface);
        Wire.put(object, "to", to_);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalReadRangeRequest that)) return false;
        return Objects.equals(format, that.format) && Objects.equals(from, that.from) && Objects.equals(markerEpoch, that.markerEpoch) && Objects.equals(maxBytes, that.maxBytes) && Objects.equals(surface, that.surface) && Objects.equals(to_, that.to_);
    }

    @Override
    public int hashCode() { return Objects.hash(format, from, markerEpoch, maxBytes, surface, to_); }

    @Override
    public String toString() { return "TerminalReadRangeRequest" + toWire(); }

    public static final class Builder {
        private Field<String> format = Field.omitted();
        private RowMarkerPoint from;
        private boolean fromSet;
        private UInt64 markerEpoch;
        private boolean markerEpochSet;
        private Field<UInt64> maxBytes = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private RowMarkerPoint to_;
        private boolean to_Set;

        public Builder format(String value) {
            this.format = Field.ofNullable(value);
            return this;
        }
        public Builder from(RowMarkerPoint value) {
            this.from = value;
            this.fromSet = true;
            return this;
        }
        public Builder markerEpoch(UInt64 value) {
            this.markerEpoch = value;
            this.markerEpochSet = true;
            return this;
        }
        public Builder maxBytes(UInt64 value) {
            this.maxBytes = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder to_(RowMarkerPoint value) {
            this.to_ = value;
            this.to_Set = true;
            return this;
        }
        public TerminalReadRangeRequest build() { return new TerminalReadRangeRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-history request. Protocol v12; authority: control. */
public final class TerminalHistoryRequest implements WireValue {
    private final Field<UInt64> before;
    private final UInt64 markerEpoch;
    private final Field<UInt64> maxBytes;
    private final UInt64 surface;

    private TerminalHistoryRequest(Builder builder) {
        this.before = builder.before;
        if (!builder.markerEpochSet) throw new IllegalArgumentException("marker_epoch is required");
        this.markerEpoch = Wire.nonNull(builder.markerEpoch, "marker_epoch");
        this.maxBytes = builder.maxBytes;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> before() { return before; }
    public UInt64 markerEpoch() { return markerEpoch; }
    public Field<UInt64> maxBytes() { return maxBytes; }
    public UInt64 surface() { return surface; }

    public static TerminalHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalHistoryRequest");
        Builder builder = builder();
        Object rawBefore = Wire.optional(object, "before");
        if (!Wire.isMissing(rawBefore)) {
            builder.before(rawBefore == null ? null : Wire.uint64(rawBefore, "TerminalHistoryRequest.before"));
        }
        Object rawMarkerEpoch = Wire.required(object, "marker_epoch");
        builder.markerEpoch(Wire.uint64(rawMarkerEpoch, "TerminalHistoryRequest.marker_epoch"));
        Object rawMaxBytes = Wire.optional(object, "max_bytes");
        if (!Wire.isMissing(rawMaxBytes)) {
            builder.maxBytes(rawMaxBytes == null ? null : Wire.uint64(rawMaxBytes, "TerminalHistoryRequest.max_bytes"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalHistoryRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "before", before);
        Wire.put(object, "marker_epoch", markerEpoch);
        Wire.put(object, "max_bytes", maxBytes);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalHistoryRequest that)) return false;
        return Objects.equals(before, that.before) && Objects.equals(markerEpoch, that.markerEpoch) && Objects.equals(maxBytes, that.maxBytes) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(before, markerEpoch, maxBytes, surface); }

    @Override
    public String toString() { return "TerminalHistoryRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> before = Field.omitted();
        private UInt64 markerEpoch;
        private boolean markerEpochSet;
        private Field<UInt64> maxBytes = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder before(UInt64 value) {
            this.before = Field.ofNullable(value);
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
        public TerminalHistoryRequest build() { return new TerminalHistoryRequest(this); }
    }
}

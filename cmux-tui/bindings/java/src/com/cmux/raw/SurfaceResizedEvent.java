// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable surface-resized event. Protocol v5; streams: subscribe. */
public final class SurfaceResizedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final int cols;
    private final UInt64 reservationId;
    private final int rows;
    private final UInt64 surface;

    private SurfaceResizedEvent(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.reservationIdSet) throw new IllegalArgumentException("reservation_id is required");
        this.reservationId = builder.reservationId;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public UInt64 reservationId() { return reservationId; }
    public int rows() { return rows; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "surface-resized"; }

    public static SurfaceResizedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SurfaceResizedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "surface-resized", "SurfaceResizedEvent.event");
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "SurfaceResizedEvent.cols"));
        Object rawReservationId = Wire.required(object, "reservation_id");
        builder.reservationId(rawReservationId == null ? null : Wire.uint64(rawReservationId, "SurfaceResizedEvent.reservation_id"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "SurfaceResizedEvent.rows"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SurfaceResizedEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "surface-resized");
        Wire.put(object, "cols", cols);
        Wire.put(object, "reservation_id", reservationId);
        Wire.put(object, "rows", rows);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SurfaceResizedEvent that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(reservationId, that.reservationId) && Objects.equals(rows, that.rows) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, reservationId, rows, surface); }

    @Override
    public String toString() { return "SurfaceResizedEvent" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private UInt64 reservationId;
        private boolean reservationIdSet;
        private Integer rows;
        private boolean rowsSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder reservationId(UInt64 value) {
            this.reservationId = value;
            this.reservationIdSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SurfaceResizedEvent build() { return new SurfaceResizedEvent(this); }
    }
}

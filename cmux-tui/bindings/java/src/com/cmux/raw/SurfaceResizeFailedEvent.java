// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable surface-resize-failed event. Protocol v7; streams: subscribe. */
public final class SurfaceResizeFailedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final int cols;
    private final String error;
    private final UInt64 reservationId;
    private final UInt64 retryAfterMs;
    private final int rows;
    private final UInt64 surface;

    private SurfaceResizeFailedEvent(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = Wire.nonNull(builder.error, "error");
        if (!builder.reservationIdSet) throw new IllegalArgumentException("reservation_id is required");
        this.reservationId = builder.reservationId;
        if (!builder.retryAfterMsSet) throw new IllegalArgumentException("retry_after_ms is required");
        this.retryAfterMs = builder.retryAfterMs;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public String error() { return error; }
    public UInt64 reservationId() { return reservationId; }
    public UInt64 retryAfterMs() { return retryAfterMs; }
    public int rows() { return rows; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "surface-resize-failed"; }

    public static SurfaceResizeFailedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SurfaceResizeFailedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "surface-resize-failed", "SurfaceResizeFailedEvent.event");
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "SurfaceResizeFailedEvent.cols"));
        Object rawError = Wire.required(object, "error");
        builder.error(Wire.string(rawError, "SurfaceResizeFailedEvent.error"));
        Object rawReservationId = Wire.required(object, "reservation_id");
        builder.reservationId(rawReservationId == null ? null : Wire.uint64(rawReservationId, "SurfaceResizeFailedEvent.reservation_id"));
        Object rawRetryAfterMs = Wire.required(object, "retry_after_ms");
        builder.retryAfterMs(rawRetryAfterMs == null ? null : Wire.uint64(rawRetryAfterMs, "SurfaceResizeFailedEvent.retry_after_ms"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "SurfaceResizeFailedEvent.rows"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SurfaceResizeFailedEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "surface-resize-failed");
        Wire.put(object, "cols", cols);
        Wire.put(object, "error", error);
        Wire.put(object, "reservation_id", reservationId);
        Wire.put(object, "retry_after_ms", retryAfterMs);
        Wire.put(object, "rows", rows);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SurfaceResizeFailedEvent that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(error, that.error) && Objects.equals(reservationId, that.reservationId) && Objects.equals(retryAfterMs, that.retryAfterMs) && Objects.equals(rows, that.rows) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, error, reservationId, retryAfterMs, rows, surface); }

    @Override
    public String toString() { return "SurfaceResizeFailedEvent" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private String error;
        private boolean errorSet;
        private UInt64 reservationId;
        private boolean reservationIdSet;
        private UInt64 retryAfterMs;
        private boolean retryAfterMsSet;
        private Integer rows;
        private boolean rowsSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder reservationId(UInt64 value) {
            this.reservationId = value;
            this.reservationIdSet = true;
            return this;
        }
        public Builder retryAfterMs(UInt64 value) {
            this.retryAfterMs = value;
            this.retryAfterMsSet = true;
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
        public SurfaceResizeFailedEvent build() { return new SurfaceResizeFailedEvent(this); }
    }
}

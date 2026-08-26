// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ResizeSurfaceResult implements WireValue {
    private final boolean accepted;
    private final UInt64 reservationId;

    private ResizeSurfaceResult(Builder builder) {
        if (!builder.acceptedSet) throw new IllegalArgumentException("accepted is required");
        this.accepted = builder.accepted;
        if (!builder.reservationIdSet) throw new IllegalArgumentException("reservation_id is required");
        this.reservationId = builder.reservationId;
    }

    public static Builder builder() { return new Builder(); }

    public boolean accepted() { return accepted; }
    public UInt64 reservationId() { return reservationId; }

    public static ResizeSurfaceResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResizeSurfaceResult");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        builder.accepted(Wire.bool(rawAccepted, "ResizeSurfaceResult.accepted"));
        Object rawReservationId = Wire.required(object, "reservation_id");
        builder.reservationId(rawReservationId == null ? null : Wire.uint64(rawReservationId, "ResizeSurfaceResult.reservation_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", accepted);
        Wire.put(object, "reservation_id", reservationId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResizeSurfaceResult that)) return false;
        return Objects.equals(accepted, that.accepted) && Objects.equals(reservationId, that.reservationId);
    }

    @Override
    public int hashCode() { return Objects.hash(accepted, reservationId); }

    @Override
    public String toString() { return "ResizeSurfaceResult" + toWire(); }

    public static final class Builder {
        private Boolean accepted;
        private boolean acceptedSet;
        private UInt64 reservationId;
        private boolean reservationIdSet;

        public Builder accepted(boolean value) {
            this.accepted = value;
            this.acceptedSet = true;
            return this;
        }
        public Builder reservationId(UInt64 value) {
            this.reservationId = value;
            this.reservationIdSet = true;
            return this;
        }
        public ResizeSurfaceResult build() { return new ResizeSurfaceResult(this); }
    }
}

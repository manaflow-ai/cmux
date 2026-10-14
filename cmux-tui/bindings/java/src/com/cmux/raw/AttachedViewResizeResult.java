// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AttachedViewResizeResult implements WireValue {
    private final boolean accepted;
    private final ViewAttachmentOutcome outcome;
    private final Field<String> participant;
    private final UInt64 reservationId;

    private AttachedViewResizeResult(Builder builder) {
        if (!builder.acceptedSet) throw new IllegalArgumentException("accepted is required");
        this.accepted = builder.accepted;
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        this.participant = builder.participant;
        if (!builder.reservationIdSet) throw new IllegalArgumentException("reservation_id is required");
        this.reservationId = builder.reservationId;
    }

    public static Builder builder() { return new Builder(); }

    public boolean accepted() { return accepted; }
    public ViewAttachmentOutcome outcome() { return outcome; }
    public Field<String> participant() { return participant; }
    public UInt64 reservationId() { return reservationId; }

    public static AttachedViewResizeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AttachedViewResizeResult");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        builder.accepted(Wire.bool(rawAccepted, "AttachedViewResizeResult.accepted"));
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(ViewAttachmentOutcome.fromWire(rawOutcome));
        Object rawParticipant = Wire.optional(object, "participant");
        if (!Wire.isMissing(rawParticipant)) {
            builder.participant(Wire.string(rawParticipant, "AttachedViewResizeResult.participant"));
        }
        Object rawReservationId = Wire.required(object, "reservation_id");
        builder.reservationId(rawReservationId == null ? null : Wire.uint64(rawReservationId, "AttachedViewResizeResult.reservation_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", accepted);
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "participant", participant);
        Wire.put(object, "reservation_id", reservationId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AttachedViewResizeResult that)) return false;
        return Objects.equals(accepted, that.accepted) && Objects.equals(outcome, that.outcome) && Objects.equals(participant, that.participant) && Objects.equals(reservationId, that.reservationId);
    }

    @Override
    public int hashCode() { return Objects.hash(accepted, outcome, participant, reservationId); }

    @Override
    public String toString() { return "AttachedViewResizeResult" + toWire(); }

    public static final class Builder {
        private Boolean accepted;
        private boolean acceptedSet;
        private ViewAttachmentOutcome outcome;
        private boolean outcomeSet;
        private Field<String> participant = Field.omitted();
        private UInt64 reservationId;
        private boolean reservationIdSet;

        public Builder accepted(boolean value) {
            this.accepted = value;
            this.acceptedSet = true;
            return this;
        }
        public Builder outcome(ViewAttachmentOutcome value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = Field.of(value);
            return this;
        }
        public Builder reservationId(UInt64 value) {
            this.reservationId = value;
            this.reservationIdSet = true;
            return this;
        }
        public AttachedViewResizeResult build() { return new AttachedViewResizeResult(this); }
    }
}

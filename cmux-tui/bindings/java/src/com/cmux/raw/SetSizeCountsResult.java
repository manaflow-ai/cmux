// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetSizeCountsResult implements WireValue {
    private final Field<Boolean> changed;
    private final ViewAttachmentOutcome outcome;
    private final Field<String> participant;

    private SetSizeCountsResult(Builder builder) {
        this.changed = builder.changed;
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        this.participant = builder.participant;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> changed() { return changed; }
    public ViewAttachmentOutcome outcome() { return outcome; }
    public Field<String> participant() { return participant; }

    public static SetSizeCountsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetSizeCountsResult");
        Builder builder = builder();
        Object rawChanged = Wire.optional(object, "changed");
        if (!Wire.isMissing(rawChanged)) {
            builder.changed(Wire.bool(rawChanged, "SetSizeCountsResult.changed"));
        }
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(ViewAttachmentOutcome.fromWire(rawOutcome));
        Object rawParticipant = Wire.optional(object, "participant");
        if (!Wire.isMissing(rawParticipant)) {
            builder.participant(Wire.string(rawParticipant, "SetSizeCountsResult.participant"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetSizeCountsResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(outcome, that.outcome) && Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, outcome, participant); }

    @Override
    public String toString() { return "SetSizeCountsResult" + toWire(); }

    public static final class Builder {
        private Field<Boolean> changed = Field.omitted();
        private ViewAttachmentOutcome outcome;
        private boolean outcomeSet;
        private Field<String> participant = Field.omitted();

        public Builder changed(Boolean value) {
            this.changed = Field.of(value);
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
        public SetSizeCountsResult build() { return new SetSizeCountsResult(this); }
    }
}

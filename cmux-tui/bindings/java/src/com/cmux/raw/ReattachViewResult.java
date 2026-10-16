// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReattachViewResult implements WireValue {
    private final String participant;
    private final SizeState state;

    private ReattachViewResult(Builder builder) {
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public String participant() { return participant; }
    public SizeState state() { return state; }

    public static ReattachViewResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReattachViewResult");
        Builder builder = builder();
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ReattachViewResult.participant"));
        Object rawState = Wire.required(object, "state");
        builder.state(SizeState.fromWire(rawState));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "participant", participant);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReattachViewResult that)) return false;
        return Objects.equals(participant, that.participant) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(participant, state); }

    @Override
    public String toString() { return "ReattachViewResult" + toWire(); }

    public static final class Builder {
        private String participant;
        private boolean participantSet;
        private SizeState state;
        private boolean stateSet;

        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder state(SizeState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public ReattachViewResult build() { return new ReattachViewResult(this); }
    }
}

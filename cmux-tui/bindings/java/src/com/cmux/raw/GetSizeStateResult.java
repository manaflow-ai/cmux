// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GetSizeStateResult implements WireValue {
    private final String selfParticipant;
    private final SizeState state;

    private GetSizeStateResult(Builder builder) {
        if (!builder.selfParticipantSet) throw new IllegalArgumentException("self_participant is required");
        this.selfParticipant = builder.selfParticipant;
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public String selfParticipant() { return selfParticipant; }
    public SizeState state() { return state; }

    public static GetSizeStateResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetSizeStateResult");
        Builder builder = builder();
        Object rawSelfParticipant = Wire.required(object, "self_participant");
        builder.selfParticipant(rawSelfParticipant == null ? null : Wire.string(rawSelfParticipant, "GetSizeStateResult.self_participant"));
        Object rawState = Wire.required(object, "state");
        builder.state(SizeState.fromWire(rawState));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "self_participant", selfParticipant);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetSizeStateResult that)) return false;
        return Objects.equals(selfParticipant, that.selfParticipant) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(selfParticipant, state); }

    @Override
    public String toString() { return "GetSizeStateResult" + toWire(); }

    public static final class Builder {
        private String selfParticipant;
        private boolean selfParticipantSet;
        private SizeState state;
        private boolean stateSet;

        public Builder selfParticipant(String value) {
            this.selfParticipant = value;
            this.selfParticipantSet = true;
            return this;
        }
        public Builder state(SizeState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public GetSizeStateResult build() { return new GetSizeStateResult(this); }
    }
}

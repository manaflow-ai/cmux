// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetStreamPriorityResult implements WireValue {
    private final SetStreamPriorityResultOutcome outcome;
    private final int stream;

    private SetStreamPriorityResult(Builder builder) {
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public SetStreamPriorityResultOutcome outcome() { return outcome; }
    public int stream() { return stream; }

    public static SetStreamPriorityResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetStreamPriorityResult");
        Builder builder = builder();
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(SetStreamPriorityResultOutcome.fromWire(rawOutcome));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "SetStreamPriorityResult.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetStreamPriorityResult that)) return false;
        return Objects.equals(outcome, that.outcome) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(outcome, stream); }

    @Override
    public String toString() { return "SetStreamPriorityResult" + toWire(); }

    public static final class Builder {
        private SetStreamPriorityResultOutcome outcome;
        private boolean outcomeSet;
        private Integer stream;
        private boolean streamSet;

        public Builder outcome(SetStreamPriorityResultOutcome value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public SetStreamPriorityResult build() { return new SetStreamPriorityResult(this); }
    }
}

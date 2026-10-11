// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationBindResult implements WireValue {
    private final String participant;

    private ConversationBindResult(Builder builder) {
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public String participant() { return participant; }

    public static ConversationBindResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationBindResult");
        Builder builder = builder();
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationBindResult.participant"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationBindResult that)) return false;
        return Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(participant); }

    @Override
    public String toString() { return "ConversationBindResult" + toWire(); }

    public static final class Builder {
        private String participant;
        private boolean participantSet;

        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public ConversationBindResult build() { return new ConversationBindResult(this); }
    }
}

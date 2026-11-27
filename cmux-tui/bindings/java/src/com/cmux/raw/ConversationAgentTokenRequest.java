// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-agent-token request. Protocol v12; authority: local-admin. */
public final class ConversationAgentTokenRequest implements WireValue {
    private final String participant;

    private ConversationAgentTokenRequest(Builder builder) {
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public String participant() { return participant; }

    public static ConversationAgentTokenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAgentTokenRequest");
        Builder builder = builder();
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationAgentTokenRequest.participant"));
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
        if (!(other instanceof ConversationAgentTokenRequest that)) return false;
        return Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(participant); }

    @Override
    public String toString() { return "ConversationAgentTokenRequest" + toWire(); }

    public static final class Builder {
        private String participant;
        private boolean participantSet;

        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public ConversationAgentTokenRequest build() { return new ConversationAgentTokenRequest(this); }
    }
}

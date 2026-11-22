// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-bind request. Protocol v12; authority: local-admin. */
public final class ConversationBindRequest implements WireValue {
    private final String participant;
    private final String token;

    private ConversationBindRequest(Builder builder) {
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        if (!builder.tokenSet) throw new IllegalArgumentException("token is required");
        this.token = Wire.nonNull(builder.token, "token");
    }

    public static Builder builder() { return new Builder(); }

    public String participant() { return participant; }
    public String token() { return token; }

    public static ConversationBindRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationBindRequest");
        Builder builder = builder();
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationBindRequest.participant"));
        Object rawToken = Wire.required(object, "token");
        builder.token(Wire.string(rawToken, "ConversationBindRequest.token"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "participant", participant);
        Wire.put(object, "token", token);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationBindRequest that)) return false;
        return Objects.equals(participant, that.participant) && Objects.equals(token, that.token);
    }

    @Override
    public int hashCode() { return Objects.hash(participant, token); }

    @Override
    public String toString() { return "ConversationBindRequest" + toWire(); }

    public static final class Builder {
        private String participant;
        private boolean participantSet;
        private String token;
        private boolean tokenSet;

        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder token(String value) {
            this.token = value;
            this.tokenSet = true;
            return this;
        }
        public ConversationBindRequest build() { return new ConversationBindRequest(this); }
    }
}

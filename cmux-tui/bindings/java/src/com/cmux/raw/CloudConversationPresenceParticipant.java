// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CloudConversationPresenceParticipant implements WireValue {
    private final String participant;
    private final boolean viewing;

    private CloudConversationPresenceParticipant(Builder builder) {
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        if (!builder.viewingSet) throw new IllegalArgumentException("viewing is required");
        this.viewing = builder.viewing;
    }

    public static Builder builder() { return new Builder(); }

    public String participant() { return participant; }
    public boolean viewing() { return viewing; }

    public static CloudConversationPresenceParticipant fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudConversationPresenceParticipant");
        Builder builder = builder();
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "CloudConversationPresenceParticipant.participant"));
        Object rawViewing = Wire.required(object, "viewing");
        builder.viewing(Wire.bool(rawViewing, "CloudConversationPresenceParticipant.viewing"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "participant", participant);
        Wire.put(object, "viewing", viewing);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudConversationPresenceParticipant that)) return false;
        return Objects.equals(participant, that.participant) && Objects.equals(viewing, that.viewing);
    }

    @Override
    public int hashCode() { return Objects.hash(participant, viewing); }

    @Override
    public String toString() { return "CloudConversationPresenceParticipant" + toWire(); }

    public static final class Builder {
        private String participant;
        private boolean participantSet;
        private Boolean viewing;
        private boolean viewingSet;

        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder viewing(boolean value) {
            this.viewing = value;
            this.viewingSet = true;
            return this;
        }
        public CloudConversationPresenceParticipant build() { return new CloudConversationPresenceParticipant(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-participant-avatar-get request. Protocol v12; authority: local-admin. */
public final class CloudParticipantAvatarGetRequest implements WireValue {
    private final String participantId;

    private CloudParticipantAvatarGetRequest(Builder builder) {
        if (!builder.participantIdSet) throw new IllegalArgumentException("participant_id is required");
        this.participantId = Wire.nonNull(builder.participantId, "participant_id");
    }

    public static Builder builder() { return new Builder(); }

    public String participantId() { return participantId; }

    public static CloudParticipantAvatarGetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudParticipantAvatarGetRequest");
        Builder builder = builder();
        Object rawParticipantId = Wire.required(object, "participant_id");
        builder.participantId(Wire.string(rawParticipantId, "CloudParticipantAvatarGetRequest.participant_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "participant_id", participantId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudParticipantAvatarGetRequest that)) return false;
        return Objects.equals(participantId, that.participantId);
    }

    @Override
    public int hashCode() { return Objects.hash(participantId); }

    @Override
    public String toString() { return "CloudParticipantAvatarGetRequest" + toWire(); }

    public static final class Builder {
        private String participantId;
        private boolean participantIdSet;

        public Builder participantId(String value) {
            this.participantId = value;
            this.participantIdSet = true;
            return this;
        }
        public CloudParticipantAvatarGetRequest build() { return new CloudParticipantAvatarGetRequest(this); }
    }
}

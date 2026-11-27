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
    private final Field<String> conversation;
    private final String participantId;

    private CloudParticipantAvatarGetRequest(Builder builder) {
        this.conversation = builder.conversation;
        if (!builder.participantIdSet) throw new IllegalArgumentException("participant_id is required");
        this.participantId = Wire.nonNull(builder.participantId, "participant_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> conversation() { return conversation; }
    public String participantId() { return participantId; }

    public static CloudParticipantAvatarGetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudParticipantAvatarGetRequest");
        Builder builder = builder();
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : Wire.string(rawConversation, "CloudParticipantAvatarGetRequest.conversation"));
        }
        Object rawParticipantId = Wire.required(object, "participant_id");
        builder.participantId(Wire.string(rawParticipantId, "CloudParticipantAvatarGetRequest.participant_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "participant_id", participantId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudParticipantAvatarGetRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(participantId, that.participantId);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, participantId); }

    @Override
    public String toString() { return "CloudParticipantAvatarGetRequest" + toWire(); }

    public static final class Builder {
        private Field<String> conversation = Field.omitted();
        private String participantId;
        private boolean participantIdSet;

        public Builder conversation(String value) {
            this.conversation = Field.ofNullable(value);
            return this;
        }
        public Builder participantId(String value) {
            this.participantId = value;
            this.participantIdSet = true;
            return this;
        }
        public CloudParticipantAvatarGetRequest build() { return new CloudParticipantAvatarGetRequest(this); }
    }
}

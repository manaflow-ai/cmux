// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationQuestionRespondent implements WireValue {
    private final Field<String> device;
    private final String displayName;
    private final String participant;
    private final Field<Boolean> remote;

    private ConversationQuestionRespondent(Builder builder) {
        this.device = builder.device;
        if (!builder.displayNameSet) throw new IllegalArgumentException("display_name is required");
        this.displayName = Wire.nonNull(builder.displayName, "display_name");
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        this.remote = builder.remote;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> device() { return device; }
    public String displayName() { return displayName; }
    public String participant() { return participant; }
    public Field<Boolean> remote() { return remote; }

    public static ConversationQuestionRespondent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationQuestionRespondent");
        Builder builder = builder();
        Object rawDevice = Wire.optional(object, "device");
        if (!Wire.isMissing(rawDevice)) {
            builder.device(rawDevice == null ? null : Wire.string(rawDevice, "ConversationQuestionRespondent.device"));
        }
        Object rawDisplayName = Wire.required(object, "display_name");
        builder.displayName(Wire.string(rawDisplayName, "ConversationQuestionRespondent.display_name"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationQuestionRespondent.participant"));
        Object rawRemote = Wire.optional(object, "remote");
        if (!Wire.isMissing(rawRemote)) {
            builder.remote(Wire.bool(rawRemote, "ConversationQuestionRespondent.remote"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "device", device);
        Wire.put(object, "display_name", displayName);
        Wire.put(object, "participant", participant);
        Wire.put(object, "remote", remote);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationQuestionRespondent that)) return false;
        return Objects.equals(device, that.device) && Objects.equals(displayName, that.displayName) && Objects.equals(participant, that.participant) && Objects.equals(remote, that.remote);
    }

    @Override
    public int hashCode() { return Objects.hash(device, displayName, participant, remote); }

    @Override
    public String toString() { return "ConversationQuestionRespondent" + toWire(); }

    public static final class Builder {
        private Field<String> device = Field.omitted();
        private String displayName;
        private boolean displayNameSet;
        private String participant;
        private boolean participantSet;
        private Field<Boolean> remote = Field.omitted();

        public Builder device(String value) {
            this.device = Field.ofNullable(value);
            return this;
        }
        public Builder displayName(String value) {
            this.displayName = value;
            this.displayNameSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder remote(Boolean value) {
            this.remote = Field.of(value);
            return this;
        }
        public ConversationQuestionRespondent build() { return new ConversationQuestionRespondent(this); }
    }
}

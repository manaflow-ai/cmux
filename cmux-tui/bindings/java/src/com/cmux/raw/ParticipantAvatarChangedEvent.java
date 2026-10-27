// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable participant-avatar-changed event. Protocol v12; streams: subscribe. */
public final class ParticipantAvatarChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Object avatar;
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final String participant;

    private ParticipantAvatarChangedEvent(Builder builder) {
        if (!builder.avatarSet) throw new IllegalArgumentException("avatar is required");
        this.avatar = builder.avatar == null ? null : Wire.immutableJson(builder.avatar);
        this.cause = builder.cause;
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public Object avatar() { return avatar; }
    public Field<EventCause> cause() { return cause; }
    public String participant() { return participant; }
    @Override public String event() { return "participant-avatar-changed"; }

    public static ParticipantAvatarChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ParticipantAvatarChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "participant-avatar-changed", "ParticipantAvatarChangedEvent.event");
        Object rawAvatar = Wire.required(object, "avatar");
        builder.avatar(rawAvatar == null ? null : Wire.immutableJson(rawAvatar));
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ParticipantAvatarChangedEvent.participant"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "participant-avatar-changed");
        Wire.put(object, "avatar", avatar);
        Wire.put(object, "cause", cause);
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ParticipantAvatarChangedEvent that)) return false;
        return Objects.equals(avatar, that.avatar) && Objects.equals(cause, that.cause) && Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(avatar, cause, participant); }

    @Override
    public String toString() { return "ParticipantAvatarChangedEvent" + toWire(); }

    public static final class Builder {
        private Object avatar;
        private boolean avatarSet;
        private Field<EventCause> cause = Field.omitted();
        private String participant;
        private boolean participantSet;

        public Builder avatar(Object value) {
            this.avatar = value;
            this.avatarSet = true;
            return this;
        }
        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public ParticipantAvatarChangedEvent build() { return new ParticipantAvatarChangedEvent(this); }
    }
}

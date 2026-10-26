// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable personal-changed event. Protocol v12; streams: subscribe. */
public final class PersonalChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final UInt64 personalRevision;

    private PersonalChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.personalRevisionSet) throw new IllegalArgumentException("personal_revision is required");
        this.personalRevision = Wire.nonNull(builder.personalRevision, "personal_revision");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public UInt64 personalRevision() { return personalRevision; }
    @Override public String event() { return "personal-changed"; }

    public static PersonalChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PersonalChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "personal-changed", "PersonalChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawPersonalRevision = Wire.required(object, "personal_revision");
        builder.personalRevision(Wire.uint64(rawPersonalRevision, "PersonalChangedEvent.personal_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "personal-changed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "personal_revision", personalRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PersonalChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(personalRevision, that.personalRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, personalRevision); }

    @Override
    public String toString() { return "PersonalChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private UInt64 personalRevision;
        private boolean personalRevisionSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder personalRevision(UInt64 value) {
            this.personalRevision = value;
            this.personalRevisionSet = true;
            return this;
        }
        public PersonalChangedEvent build() { return new PersonalChangedEvent(this); }
    }
}

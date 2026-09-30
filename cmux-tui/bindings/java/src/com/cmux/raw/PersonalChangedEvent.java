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
    private final UInt64 personalRevision;

    private PersonalChangedEvent(Builder builder) {
        if (!builder.personalRevisionSet) throw new IllegalArgumentException("personal_revision is required");
        this.personalRevision = Wire.nonNull(builder.personalRevision, "personal_revision");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 personalRevision() { return personalRevision; }
    @Override public String event() { return "personal-changed"; }

    public static PersonalChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PersonalChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "personal-changed", "PersonalChangedEvent.event");
        Object rawPersonalRevision = Wire.required(object, "personal_revision");
        builder.personalRevision(Wire.uint64(rawPersonalRevision, "PersonalChangedEvent.personal_revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "personal-changed");
        Wire.put(object, "personal_revision", personalRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PersonalChangedEvent that)) return false;
        return Objects.equals(personalRevision, that.personalRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(personalRevision); }

    @Override
    public String toString() { return "PersonalChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 personalRevision;
        private boolean personalRevisionSet;

        public Builder personalRevision(UInt64 value) {
            this.personalRevision = value;
            this.personalRevisionSet = true;
            return this;
        }
        public PersonalChangedEvent build() { return new PersonalChangedEvent(this); }
    }
}

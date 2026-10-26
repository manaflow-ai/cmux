// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable chief-changed event. Protocol v12; streams: subscribe. */
public final class ChiefChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final ChiefChangedEventChange change;
    private final String chief;

    private ChiefChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.changeSet) throw new IllegalArgumentException("change is required");
        this.change = Wire.nonNull(builder.change, "change");
        if (!builder.chiefSet) throw new IllegalArgumentException("chief is required");
        this.chief = Wire.nonNull(builder.chief, "chief");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public ChiefChangedEventChange change() { return change; }
    public String chief() { return chief; }
    @Override public String event() { return "chief-changed"; }

    public static ChiefChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "chief-changed", "ChiefChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawChange = Wire.required(object, "change");
        builder.change(ChiefChangedEventChange.fromWire(rawChange));
        Object rawChief = Wire.required(object, "chief");
        builder.chief(Wire.string(rawChief, "ChiefChangedEvent.chief"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "chief-changed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "change", change);
        Wire.put(object, "chief", chief);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(change, that.change) && Objects.equals(chief, that.chief);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, change, chief); }

    @Override
    public String toString() { return "ChiefChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private ChiefChangedEventChange change;
        private boolean changeSet;
        private String chief;
        private boolean chiefSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder change(ChiefChangedEventChange value) {
            this.change = value;
            this.changeSet = true;
            return this;
        }
        public Builder chief(String value) {
            this.chief = value;
            this.chiefSet = true;
            return this;
        }
        public ChiefChangedEvent build() { return new ChiefChangedEvent(this); }
    }
}

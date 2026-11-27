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
    private final ChiefChangedEventChange change;
    private final String chief;

    private ChiefChangedEvent(Builder builder) {
        if (!builder.changeSet) throw new IllegalArgumentException("change is required");
        this.change = Wire.nonNull(builder.change, "change");
        if (!builder.chiefSet) throw new IllegalArgumentException("chief is required");
        this.chief = Wire.nonNull(builder.chief, "chief");
    }

    public static Builder builder() { return new Builder(); }

    public ChiefChangedEventChange change() { return change; }
    public String chief() { return chief; }
    @Override public String event() { return "chief-changed"; }

    public static ChiefChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "chief-changed", "ChiefChangedEvent.event");
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
        Wire.put(object, "change", change);
        Wire.put(object, "chief", chief);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefChangedEvent that)) return false;
        return Objects.equals(change, that.change) && Objects.equals(chief, that.chief);
    }

    @Override
    public int hashCode() { return Objects.hash(change, chief); }

    @Override
    public String toString() { return "ChiefChangedEvent" + toWire(); }

    public static final class Builder {
        private ChiefChangedEventChange change;
        private boolean changeSet;
        private String chief;
        private boolean chiefSet;

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

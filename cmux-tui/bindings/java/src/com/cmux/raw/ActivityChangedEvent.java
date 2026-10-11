// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable activity-changed event. Protocol v12; streams: control. */
public final class ActivityChangedEvent implements WireValue, ProtocolEvent {
    private final ActivitySnapshot activity;

    private ActivityChangedEvent(Builder builder) {
        if (!builder.activitySet) throw new IllegalArgumentException("activity is required");
        this.activity = Wire.nonNull(builder.activity, "activity");
    }

    public static Builder builder() { return new Builder(); }

    public ActivitySnapshot activity() { return activity; }
    @Override public String event() { return "activity-changed"; }

    public static ActivityChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ActivityChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "activity-changed", "ActivityChangedEvent.event");
        Object rawActivity = Wire.required(object, "activity");
        builder.activity(ActivitySnapshot.fromWire(rawActivity));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "activity-changed");
        Wire.put(object, "activity", activity);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ActivityChangedEvent that)) return false;
        return Objects.equals(activity, that.activity);
    }

    @Override
    public int hashCode() { return Objects.hash(activity); }

    @Override
    public String toString() { return "ActivityChangedEvent" + toWire(); }

    public static final class Builder {
        private ActivitySnapshot activity;
        private boolean activitySet;

        public Builder activity(ActivitySnapshot value) {
            this.activity = value;
            this.activitySet = true;
            return this;
        }
        public ActivityChangedEvent build() { return new ActivityChangedEvent(this); }
    }
}

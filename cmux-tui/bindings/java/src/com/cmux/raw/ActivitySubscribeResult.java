// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ActivitySubscribeResult implements WireValue {
    private final ActivitySnapshot activity;

    private ActivitySubscribeResult(Builder builder) {
        if (!builder.activitySet) throw new IllegalArgumentException("activity is required");
        this.activity = Wire.nonNull(builder.activity, "activity");
    }

    public static Builder builder() { return new Builder(); }

    public ActivitySnapshot activity() { return activity; }

    public static ActivitySubscribeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ActivitySubscribeResult");
        Builder builder = builder();
        Object rawActivity = Wire.required(object, "activity");
        builder.activity(ActivitySnapshot.fromWire(rawActivity));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activity", activity);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ActivitySubscribeResult that)) return false;
        return Objects.equals(activity, that.activity);
    }

    @Override
    public int hashCode() { return Objects.hash(activity); }

    @Override
    public String toString() { return "ActivitySubscribeResult" + toWire(); }

    public static final class Builder {
        private ActivitySnapshot activity;
        private boolean activitySet;

        public Builder activity(ActivitySnapshot value) {
            this.activity = value;
            this.activitySet = true;
            return this;
        }
        public ActivitySubscribeResult build() { return new ActivitySubscribeResult(this); }
    }
}

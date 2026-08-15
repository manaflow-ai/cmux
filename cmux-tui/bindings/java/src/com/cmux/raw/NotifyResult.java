// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class NotifyResult implements WireValue {
    private final UInt64 notification;

    private NotifyResult(Builder builder) {
        if (!builder.notificationSet) throw new IllegalArgumentException("notification is required");
        this.notification = Wire.nonNull(builder.notification, "notification");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 notification() { return notification; }

    public static NotifyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NotifyResult");
        Builder builder = builder();
        Object rawNotification = Wire.required(object, "notification");
        builder.notification(Wire.uint64(rawNotification, "NotifyResult.notification"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "notification", notification);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NotifyResult that)) return false;
        return Objects.equals(notification, that.notification);
    }

    @Override
    public int hashCode() { return Objects.hash(notification); }

    @Override
    public String toString() { return "NotifyResult" + toWire(); }

    public static final class Builder {
        private UInt64 notification;
        private boolean notificationSet;

        public Builder notification(UInt64 value) {
            this.notification = value;
            this.notificationSet = true;
            return this;
        }
        public NotifyResult build() { return new NotifyResult(this); }
    }
}

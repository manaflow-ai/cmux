// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable record-notification-delivery request. Protocol v12; authority: control. */
public final class RecordNotificationDeliveryRequest implements WireValue {
    /** shown or suppressed. */
    private final String desktop;
    private final UInt64 notification;
    /** Why: viewed, typing, muted, quiet-hours, desktop-never, app-active, poster-no-banner, permission-denied, incognito, digest. */
    private final Field<String> reason;

    private RecordNotificationDeliveryRequest(Builder builder) {
        if (!builder.desktopSet) throw new IllegalArgumentException("desktop is required");
        this.desktop = Wire.nonNull(builder.desktop, "desktop");
        if (!builder.notificationSet) throw new IllegalArgumentException("notification is required");
        this.notification = Wire.nonNull(builder.notification, "notification");
        this.reason = builder.reason;
    }

    public static Builder builder() { return new Builder(); }

    public String desktop() { return desktop; }
    public UInt64 notification() { return notification; }
    public Field<String> reason() { return reason; }

    public static RecordNotificationDeliveryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RecordNotificationDeliveryRequest");
        Builder builder = builder();
        Object rawDesktop = Wire.required(object, "desktop");
        builder.desktop(Wire.string(rawDesktop, "RecordNotificationDeliveryRequest.desktop"));
        Object rawNotification = Wire.required(object, "notification");
        builder.notification(Wire.uint64(rawNotification, "RecordNotificationDeliveryRequest.notification"));
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : Wire.string(rawReason, "RecordNotificationDeliveryRequest.reason"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "desktop", desktop);
        Wire.put(object, "notification", notification);
        Wire.put(object, "reason", reason);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RecordNotificationDeliveryRequest that)) return false;
        return Objects.equals(desktop, that.desktop) && Objects.equals(notification, that.notification) && Objects.equals(reason, that.reason);
    }

    @Override
    public int hashCode() { return Objects.hash(desktop, notification, reason); }

    @Override
    public String toString() { return "RecordNotificationDeliveryRequest" + toWire(); }

    public static final class Builder {
        private String desktop;
        private boolean desktopSet;
        private UInt64 notification;
        private boolean notificationSet;
        private Field<String> reason = Field.omitted();

        public Builder desktop(String value) {
            this.desktop = value;
            this.desktopSet = true;
            return this;
        }
        public Builder notification(UInt64 value) {
            this.notification = value;
            this.notificationSet = true;
            return this;
        }
        public Builder reason(String value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public RecordNotificationDeliveryRequest build() { return new RecordNotificationDeliveryRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class NotificationMarker implements WireValue {
    private final NotificationLevel level;
    private final UInt64 notification;
    private final boolean unread;

    private NotificationMarker(Builder builder) {
        if (!builder.levelSet) throw new IllegalArgumentException("level is required");
        this.level = Wire.nonNull(builder.level, "level");
        if (!builder.notificationSet) throw new IllegalArgumentException("notification is required");
        this.notification = Wire.nonNull(builder.notification, "notification");
        if (!builder.unreadSet) throw new IllegalArgumentException("unread is required");
        this.unread = builder.unread;
    }

    public static Builder builder() { return new Builder(); }

    public NotificationLevel level() { return level; }
    public UInt64 notification() { return notification; }
    public boolean unread() { return unread; }

    public static NotificationMarker fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NotificationMarker");
        Builder builder = builder();
        Object rawLevel = Wire.required(object, "level");
        builder.level(NotificationLevel.fromWire(rawLevel));
        Object rawNotification = Wire.required(object, "notification");
        builder.notification(Wire.uint64(rawNotification, "NotificationMarker.notification"));
        Object rawUnread = Wire.required(object, "unread");
        builder.unread(Wire.bool(rawUnread, "NotificationMarker.unread"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "level", level);
        Wire.put(object, "notification", notification);
        Wire.put(object, "unread", unread);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NotificationMarker that)) return false;
        return Objects.equals(level, that.level) && Objects.equals(notification, that.notification) && Objects.equals(unread, that.unread);
    }

    @Override
    public int hashCode() { return Objects.hash(level, notification, unread); }

    @Override
    public String toString() { return "NotificationMarker" + toWire(); }

    public static final class Builder {
        private NotificationLevel level;
        private boolean levelSet;
        private UInt64 notification;
        private boolean notificationSet;
        private Boolean unread;
        private boolean unreadSet;

        public Builder level(NotificationLevel value) {
            this.level = value;
            this.levelSet = true;
            return this;
        }
        public Builder notification(UInt64 value) {
            this.notification = value;
            this.notificationSet = true;
            return this;
        }
        public Builder unread(boolean value) {
            this.unread = value;
            this.unreadSet = true;
            return this;
        }
        public NotificationMarker build() { return new NotificationMarker(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable notification event. Protocol v6; streams: subscribe, attach-byte, attach-browser. */
public final class NotificationEvent implements WireValue, BrowserAttachEvent, ByteAttachEvent, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String body;
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final Field<Boolean> desktop;
    private final NotificationLevel level;
    private final UInt64 notification;
    private final Field<Boolean> reply;
    private final Field<NotificationSource> source;
    private final UInt64 surface;
    private final String title;

    private NotificationEvent(Builder builder) {
        if (!builder.bodySet) throw new IllegalArgumentException("body is required");
        this.body = Wire.nonNull(builder.body, "body");
        this.cause = builder.cause;
        this.desktop = builder.desktop;
        if (!builder.levelSet) throw new IllegalArgumentException("level is required");
        this.level = Wire.nonNull(builder.level, "level");
        if (!builder.notificationSet) throw new IllegalArgumentException("notification is required");
        this.notification = Wire.nonNull(builder.notification, "notification");
        this.reply = builder.reply;
        this.source = builder.source;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = builder.surface;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String body() { return body; }
    public Field<EventCause> cause() { return cause; }
    public Field<Boolean> desktop() { return desktop; }
    public NotificationLevel level() { return level; }
    public UInt64 notification() { return notification; }
    public Field<Boolean> reply() { return reply; }
    public Field<NotificationSource> source() { return source; }
    public UInt64 surface() { return surface; }
    public String title() { return title; }
    @Override public String event() { return "notification"; }

    public static NotificationEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NotificationEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "notification", "NotificationEvent.event");
        Object rawBody = Wire.required(object, "body");
        builder.body(Wire.string(rawBody, "NotificationEvent.body"));
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawDesktop = Wire.optional(object, "desktop");
        if (!Wire.isMissing(rawDesktop)) {
            builder.desktop(Wire.bool(rawDesktop, "NotificationEvent.desktop"));
        }
        Object rawLevel = Wire.required(object, "level");
        builder.level(NotificationLevel.fromWire(rawLevel));
        Object rawNotification = Wire.required(object, "notification");
        builder.notification(Wire.uint64(rawNotification, "NotificationEvent.notification"));
        Object rawReply = Wire.optional(object, "reply");
        if (!Wire.isMissing(rawReply)) {
            builder.reply(Wire.bool(rawReply, "NotificationEvent.reply"));
        }
        Object rawSource = Wire.optional(object, "source");
        if (!Wire.isMissing(rawSource)) {
            builder.source(NotificationSource.fromWire(rawSource));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "NotificationEvent.surface"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "NotificationEvent.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "notification");
        Wire.put(object, "body", body);
        Wire.put(object, "cause", cause);
        Wire.put(object, "desktop", desktop);
        Wire.put(object, "level", level);
        Wire.put(object, "notification", notification);
        Wire.put(object, "reply", reply);
        Wire.put(object, "source", source);
        Wire.put(object, "surface", surface);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NotificationEvent that)) return false;
        return Objects.equals(body, that.body) && Objects.equals(cause, that.cause) && Objects.equals(desktop, that.desktop) && Objects.equals(level, that.level) && Objects.equals(notification, that.notification) && Objects.equals(reply, that.reply) && Objects.equals(source, that.source) && Objects.equals(surface, that.surface) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(body, cause, desktop, level, notification, reply, source, surface, title); }

    @Override
    public String toString() { return "NotificationEvent" + toWire(); }

    public static final class Builder {
        private String body;
        private boolean bodySet;
        private Field<EventCause> cause = Field.omitted();
        private Field<Boolean> desktop = Field.omitted();
        private NotificationLevel level;
        private boolean levelSet;
        private UInt64 notification;
        private boolean notificationSet;
        private Field<Boolean> reply = Field.omitted();
        private Field<NotificationSource> source = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private String title;
        private boolean titleSet;

        public Builder body(String value) {
            this.body = value;
            this.bodySet = true;
            return this;
        }
        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder desktop(Boolean value) {
            this.desktop = Field.of(value);
            return this;
        }
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
        public Builder reply(Boolean value) {
            this.reply = Field.of(value);
            return this;
        }
        public Builder source(NotificationSource value) {
            this.source = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public NotificationEvent build() { return new NotificationEvent(this); }
    }
}

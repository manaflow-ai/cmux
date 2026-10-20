// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable notify request. Protocol v6; authority: control. */
public final class NotifyRequest implements WireValue {
    private final String body;
    private final Field<NotificationLevel> level;
    private final Field<UInt64> surface;
    private final String title;

    private NotifyRequest(Builder builder) {
        if (!builder.bodySet) throw new IllegalArgumentException("body is required");
        this.body = Wire.nonNull(builder.body, "body");
        this.level = builder.level;
        this.surface = builder.surface;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String body() { return body; }
    public Field<NotificationLevel> level() { return level; }
    public Field<UInt64> surface() { return surface; }
    public String title() { return title; }

    public static NotifyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NotifyRequest");
        Builder builder = builder();
        Object rawBody = Wire.required(object, "body");
        builder.body(Wire.string(rawBody, "NotifyRequest.body"));
        Object rawLevel = Wire.optional(object, "level");
        if (!Wire.isMissing(rawLevel)) {
            builder.level(rawLevel == null ? null : NotificationLevel.fromWire(rawLevel));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "NotifyRequest.surface"));
        }
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "NotifyRequest.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "body", body);
        Wire.put(object, "level", level);
        Wire.put(object, "surface", surface);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NotifyRequest that)) return false;
        return Objects.equals(body, that.body) && Objects.equals(level, that.level) && Objects.equals(surface, that.surface) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(body, level, surface, title); }

    @Override
    public String toString() { return "NotifyRequest" + toWire(); }

    public static final class Builder {
        private String body;
        private boolean bodySet;
        private Field<NotificationLevel> level = Field.omitted();
        private Field<UInt64> surface = Field.omitted();
        private String title;
        private boolean titleSet;

        public Builder body(String value) {
            this.body = value;
            this.bodySet = true;
            return this;
        }
        public Builder level(NotificationLevel value) {
            this.level = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public NotifyRequest build() { return new NotifyRequest(this); }
    }
}

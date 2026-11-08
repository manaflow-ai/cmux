// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Tab implements WireValue {
    private final Field<String> browserError;
    private final Field<Boolean> browserFramesStalled;
    private final TabBrowserSource browserSource;
    private final Field<TabBrowserStatus> browserStatus;
    private final boolean dead;
    private final TabKind kind;
    private final String name;
    private final Field<NotificationMarker> notification;
    private final Field<String> shortId;
    private final Size size;
    private final Field<Boolean> supportsClearHistoryKeyFallback;
    private final UInt64 surface;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;
    private final Field<String> terminalResourceId;
    private final String title;

    private Tab(Builder builder) {
        this.browserError = builder.browserError;
        this.browserFramesStalled = builder.browserFramesStalled;
        if (!builder.browserSourceSet) throw new IllegalArgumentException("browser_source is required");
        this.browserSource = builder.browserSource;
        this.browserStatus = builder.browserStatus;
        if (!builder.deadSet) throw new IllegalArgumentException("dead is required");
        this.dead = builder.dead;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        this.notification = builder.notification;
        this.shortId = builder.shortId;
        if (!builder.sizeSet) throw new IllegalArgumentException("size is required");
        this.size = builder.size;
        this.supportsClearHistoryKeyFallback = builder.supportsClearHistoryKeyFallback;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
        this.terminalResourceId = builder.terminalResourceId;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> browserError() { return browserError; }
    public Field<Boolean> browserFramesStalled() { return browserFramesStalled; }
    public TabBrowserSource browserSource() { return browserSource; }
    public Field<TabBrowserStatus> browserStatus() { return browserStatus; }
    public boolean dead() { return dead; }
    public TabKind kind() { return kind; }
    public String name() { return name; }
    public Field<NotificationMarker> notification() { return notification; }
    public Field<String> shortId() { return shortId; }
    public Size size() { return size; }
    public Field<Boolean> supportsClearHistoryKeyFallback() { return supportsClearHistoryKeyFallback; }
    public UInt64 surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }
    public Field<String> terminalResourceId() { return terminalResourceId; }
    public String title() { return title; }

    public static Tab fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Tab");
        Builder builder = builder();
        Object rawBrowserError = Wire.optional(object, "browser_error");
        if (!Wire.isMissing(rawBrowserError)) {
            builder.browserError(rawBrowserError == null ? null : Wire.string(rawBrowserError, "Tab.browser_error"));
        }
        Object rawBrowserFramesStalled = Wire.optional(object, "browser_frames_stalled");
        if (!Wire.isMissing(rawBrowserFramesStalled)) {
            builder.browserFramesStalled(rawBrowserFramesStalled == null ? null : Wire.bool(rawBrowserFramesStalled, "Tab.browser_frames_stalled"));
        }
        Object rawBrowserSource = Wire.required(object, "browser_source");
        builder.browserSource(rawBrowserSource == null ? null : TabBrowserSource.fromWire(rawBrowserSource));
        Object rawBrowserStatus = Wire.optional(object, "browser_status");
        if (!Wire.isMissing(rawBrowserStatus)) {
            builder.browserStatus(rawBrowserStatus == null ? null : TabBrowserStatus.fromWire(rawBrowserStatus));
        }
        Object rawDead = Wire.required(object, "dead");
        builder.dead(Wire.bool(rawDead, "Tab.dead"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(TabKind.fromWire(rawKind));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "Tab.name"));
        Object rawNotification = Wire.optional(object, "notification");
        if (!Wire.isMissing(rawNotification)) {
            builder.notification(rawNotification == null ? null : NotificationMarker.fromWire(rawNotification));
        }
        Object rawShortId = Wire.optional(object, "short_id");
        if (!Wire.isMissing(rawShortId)) {
            builder.shortId(Wire.string(rawShortId, "Tab.short_id"));
        }
        Object rawSize = Wire.required(object, "size");
        builder.size(rawSize == null ? null : Size.fromWire(rawSize));
        Object rawSupportsClearHistoryKeyFallback = Wire.optional(object, "supports_clear_history_key_fallback");
        if (!Wire.isMissing(rawSupportsClearHistoryKeyFallback)) {
            builder.supportsClearHistoryKeyFallback(Wire.bool(rawSupportsClearHistoryKeyFallback, "Tab.supports_clear_history_key_fallback"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "Tab.surface"));
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "Tab.terminal_id"));
        }
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "Tab.terminal_incarnation"));
        }
        Object rawTerminalResourceId = Wire.optional(object, "terminal_resource_id");
        if (!Wire.isMissing(rawTerminalResourceId)) {
            builder.terminalResourceId(rawTerminalResourceId == null ? null : Wire.string(rawTerminalResourceId, "Tab.terminal_resource_id"));
        }
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "Tab.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_error", browserError);
        Wire.put(object, "browser_frames_stalled", browserFramesStalled);
        Wire.put(object, "browser_source", browserSource);
        Wire.put(object, "browser_status", browserStatus);
        Wire.put(object, "dead", dead);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "notification", notification);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "size", size);
        Wire.put(object, "supports_clear_history_key_fallback", supportsClearHistoryKeyFallback);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "terminal_resource_id", terminalResourceId);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Tab that)) return false;
        return Objects.equals(browserError, that.browserError) && Objects.equals(browserFramesStalled, that.browserFramesStalled) && Objects.equals(browserSource, that.browserSource) && Objects.equals(browserStatus, that.browserStatus) && Objects.equals(dead, that.dead) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(notification, that.notification) && Objects.equals(shortId, that.shortId) && Objects.equals(size, that.size) && Objects.equals(supportsClearHistoryKeyFallback, that.supportsClearHistoryKeyFallback) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(terminalResourceId, that.terminalResourceId) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(browserError, browserFramesStalled, browserSource, browserStatus, dead, kind, name, notification, shortId, size, supportsClearHistoryKeyFallback, surface, terminalId, terminalIncarnation, terminalResourceId, title); }

    @Override
    public String toString() { return "Tab" + toWire(); }

    public static final class Builder {
        private Field<String> browserError = Field.omitted();
        private Field<Boolean> browserFramesStalled = Field.omitted();
        private TabBrowserSource browserSource;
        private boolean browserSourceSet;
        private Field<TabBrowserStatus> browserStatus = Field.omitted();
        private Boolean dead;
        private boolean deadSet;
        private TabKind kind;
        private boolean kindSet;
        private String name;
        private boolean nameSet;
        private Field<NotificationMarker> notification = Field.omitted();
        private Field<String> shortId = Field.omitted();
        private Size size;
        private boolean sizeSet;
        private Field<Boolean> supportsClearHistoryKeyFallback = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();
        private Field<String> terminalResourceId = Field.omitted();
        private String title;
        private boolean titleSet;

        public Builder browserError(String value) {
            this.browserError = Field.ofNullable(value);
            return this;
        }
        public Builder browserFramesStalled(Boolean value) {
            this.browserFramesStalled = Field.ofNullable(value);
            return this;
        }
        public Builder browserSource(TabBrowserSource value) {
            this.browserSource = value;
            this.browserSourceSet = true;
            return this;
        }
        public Builder browserStatus(TabBrowserStatus value) {
            this.browserStatus = Field.ofNullable(value);
            return this;
        }
        public Builder dead(boolean value) {
            this.dead = value;
            this.deadSet = true;
            return this;
        }
        public Builder kind(TabKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder notification(NotificationMarker value) {
            this.notification = Field.ofNullable(value);
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = Field.of(value);
            return this;
        }
        public Builder size(Size value) {
            this.size = value;
            this.sizeSet = true;
            return this;
        }
        public Builder supportsClearHistoryKeyFallback(Boolean value) {
            this.supportsClearHistoryKeyFallback = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = Field.ofNullable(value);
            return this;
        }
        public Builder terminalResourceId(String value) {
            this.terminalResourceId = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Tab build() { return new Tab(this); }
    }
}

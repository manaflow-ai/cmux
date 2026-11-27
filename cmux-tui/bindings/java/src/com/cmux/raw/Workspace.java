// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Workspace implements WireValue {
    private final boolean active;
    /** The app an app workspace shows. */
    private final Field<String> app;
    /** The workspace color. */
    private final Field<String> color;
    /** The sidebar group the workspace is in. */
    private final Field<String> group;
    /** The workspace icon. */
    private final Field<String> icon;
    private final UInt64 id;
    /** workspace-keep-awake-v1: the freeing timer never ends this workspace's shells. */
    private final Field<Boolean> keepAwake;
    private final Field<String> key;
    /** What the workspace is. */
    private final Field<WorkspaceKind> kind;
    /** The person marked the workspace unread. */
    private final Field<Boolean> markedUnread;
    private final String name;
    private final Field<String> nameRevision;
    private final Field<NameSource> nameSource;
    /** The workspace is pinned. */
    private final Field<Boolean> pinned;
    /** workspace-recovered-v1: every tab is a recovered terminal. */
    private final Field<Boolean> recovered;
    /** The workspace's public id. */
    private final Field<String> resourceId;
    /** The workspace's screen group runs. */
    private final Field<List<ScreenGroupRun>> screenGroups;
    private final List<Screen> screens;
    private final Field<String> shortId;
    /** The workspace title. */
    private final Field<String> title;
    /** Tabs with an unread notification. */
    private final Field<UInt64> unreadCount;

    private Workspace(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        this.app = builder.app;
        this.color = builder.color;
        this.group = builder.group;
        this.icon = builder.icon;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        this.keepAwake = builder.keepAwake;
        this.key = builder.key;
        this.kind = builder.kind;
        this.markedUnread = builder.markedUnread;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.nameRevision = builder.nameRevision;
        this.nameSource = builder.nameSource;
        this.pinned = builder.pinned;
        this.recovered = builder.recovered;
        this.resourceId = builder.resourceId;
        this.screenGroups = builder.screenGroups.map(value -> List.copyOf(value));
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
        this.shortId = builder.shortId;
        this.title = builder.title;
        this.unreadCount = builder.unreadCount;
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public Field<String> app() { return app; }
    public Field<String> color() { return color; }
    public Field<String> group() { return group; }
    public Field<String> icon() { return icon; }
    public UInt64 id() { return id; }
    public Field<Boolean> keepAwake() { return keepAwake; }
    public Field<String> key() { return key; }
    public Field<WorkspaceKind> kind() { return kind; }
    public Field<Boolean> markedUnread() { return markedUnread; }
    public String name() { return name; }
    public Field<String> nameRevision() { return nameRevision; }
    public Field<NameSource> nameSource() { return nameSource; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<Boolean> recovered() { return recovered; }
    public Field<String> resourceId() { return resourceId; }
    public Field<List<ScreenGroupRun>> screenGroups() { return screenGroups; }
    public List<Screen> screens() { return screens; }
    public Field<String> shortId() { return shortId; }
    public Field<String> title() { return title; }
    public Field<UInt64> unreadCount() { return unreadCount; }

    public static Workspace fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Workspace");
        Builder builder = builder();
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "Workspace.active"));
        Object rawApp = Wire.optional(object, "app");
        if (!Wire.isMissing(rawApp)) {
            builder.app(rawApp == null ? null : Wire.string(rawApp, "Workspace.app"));
        }
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "Workspace.color"));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "Workspace.group"));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "Workspace.icon"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "Workspace.id"));
        Object rawKeepAwake = Wire.optional(object, "keep_awake");
        if (!Wire.isMissing(rawKeepAwake)) {
            builder.keepAwake(Wire.bool(rawKeepAwake, "Workspace.keep_awake"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(Wire.string(rawKey, "Workspace.key"));
        }
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(WorkspaceKind.fromWire(rawKind));
        }
        Object rawMarkedUnread = Wire.optional(object, "marked_unread");
        if (!Wire.isMissing(rawMarkedUnread)) {
            builder.markedUnread(Wire.bool(rawMarkedUnread, "Workspace.marked_unread"));
        }
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "Workspace.name"));
        Object rawNameRevision = Wire.optional(object, "name_revision");
        if (!Wire.isMissing(rawNameRevision)) {
            builder.nameRevision(Wire.string(rawNameRevision, "Workspace.name_revision"));
        }
        Object rawNameSource = Wire.optional(object, "name_source");
        if (!Wire.isMissing(rawNameSource)) {
            builder.nameSource(NameSource.fromWire(rawNameSource));
        }
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(Wire.bool(rawPinned, "Workspace.pinned"));
        }
        Object rawRecovered = Wire.optional(object, "recovered");
        if (!Wire.isMissing(rawRecovered)) {
            builder.recovered(Wire.bool(rawRecovered, "Workspace.recovered"));
        }
        Object rawResourceId = Wire.optional(object, "resource_id");
        if (!Wire.isMissing(rawResourceId)) {
            builder.resourceId(rawResourceId == null ? null : Wire.string(rawResourceId, "Workspace.resource_id"));
        }
        Object rawScreenGroups = Wire.optional(object, "screen_groups");
        if (!Wire.isMissing(rawScreenGroups)) {
            builder.screenGroups(Wire.array(rawScreenGroups, "Workspace.screen_groups", item -> ScreenGroupRun.fromWire(item)));
        }
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "Workspace.screens", item -> Screen.fromWire(item)));
        Object rawShortId = Wire.optional(object, "short_id");
        if (!Wire.isMissing(rawShortId)) {
            builder.shortId(Wire.string(rawShortId, "Workspace.short_id"));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "Workspace.title"));
        }
        Object rawUnreadCount = Wire.optional(object, "unread_count");
        if (!Wire.isMissing(rawUnreadCount)) {
            builder.unreadCount(Wire.uint64(rawUnreadCount, "Workspace.unread_count"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "active", active);
        Wire.put(object, "app", app);
        Wire.put(object, "color", color);
        Wire.put(object, "group", group);
        Wire.put(object, "icon", icon);
        Wire.put(object, "id", id);
        Wire.put(object, "keep_awake", keepAwake);
        Wire.put(object, "key", key);
        Wire.put(object, "kind", kind);
        Wire.put(object, "marked_unread", markedUnread);
        Wire.put(object, "name", name);
        Wire.put(object, "name_revision", nameRevision);
        Wire.put(object, "name_source", nameSource);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "recovered", recovered);
        Wire.put(object, "resource_id", resourceId);
        Wire.put(object, "screen_groups", screenGroups);
        Wire.put(object, "screens", screens);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "title", title);
        Wire.put(object, "unread_count", unreadCount);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Workspace that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(app, that.app) && Objects.equals(color, that.color) && Objects.equals(group, that.group) && Objects.equals(icon, that.icon) && Objects.equals(id, that.id) && Objects.equals(keepAwake, that.keepAwake) && Objects.equals(key, that.key) && Objects.equals(kind, that.kind) && Objects.equals(markedUnread, that.markedUnread) && Objects.equals(name, that.name) && Objects.equals(nameRevision, that.nameRevision) && Objects.equals(nameSource, that.nameSource) && Objects.equals(pinned, that.pinned) && Objects.equals(recovered, that.recovered) && Objects.equals(resourceId, that.resourceId) && Objects.equals(screenGroups, that.screenGroups) && Objects.equals(screens, that.screens) && Objects.equals(shortId, that.shortId) && Objects.equals(title, that.title) && Objects.equals(unreadCount, that.unreadCount);
    }

    @Override
    public int hashCode() { return Objects.hash(active, app, color, group, icon, id, keepAwake, key, kind, markedUnread, name, nameRevision, nameSource, pinned, recovered, resourceId, screenGroups, screens, shortId, title, unreadCount); }

    @Override
    public String toString() { return "Workspace" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private Field<String> app = Field.omitted();
        private Field<String> color = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<String> icon = Field.omitted();
        private UInt64 id;
        private boolean idSet;
        private Field<Boolean> keepAwake = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<WorkspaceKind> kind = Field.omitted();
        private Field<Boolean> markedUnread = Field.omitted();
        private String name;
        private boolean nameSet;
        private Field<String> nameRevision = Field.omitted();
        private Field<NameSource> nameSource = Field.omitted();
        private Field<Boolean> pinned = Field.omitted();
        private Field<Boolean> recovered = Field.omitted();
        private Field<String> resourceId = Field.omitted();
        private Field<List<ScreenGroupRun>> screenGroups = Field.omitted();
        private List<Screen> screens;
        private boolean screensSet;
        private Field<String> shortId = Field.omitted();
        private Field<String> title = Field.omitted();
        private Field<UInt64> unreadCount = Field.omitted();

        public Builder active(boolean value) {
            this.active = value;
            this.activeSet = true;
            return this;
        }
        public Builder app(String value) {
            this.app = Field.ofNullable(value);
            return this;
        }
        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder keepAwake(Boolean value) {
            this.keepAwake = Field.of(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.of(value);
            return this;
        }
        public Builder kind(WorkspaceKind value) {
            this.kind = Field.of(value);
            return this;
        }
        public Builder markedUnread(Boolean value) {
            this.markedUnread = Field.of(value);
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder nameRevision(String value) {
            this.nameRevision = Field.of(value);
            return this;
        }
        public Builder nameSource(NameSource value) {
            this.nameSource = Field.of(value);
            return this;
        }
        public Builder pinned(Boolean value) {
            this.pinned = Field.of(value);
            return this;
        }
        public Builder recovered(Boolean value) {
            this.recovered = Field.of(value);
            return this;
        }
        public Builder resourceId(String value) {
            this.resourceId = Field.ofNullable(value);
            return this;
        }
        public Builder screenGroups(List<ScreenGroupRun> value) {
            this.screenGroups = Field.of(value);
            return this;
        }
        public Builder screens(List<Screen> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = Field.of(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.ofNullable(value);
            return this;
        }
        public Builder unreadCount(UInt64 value) {
            this.unreadCount = Field.of(value);
            return this;
        }
        public Workspace build() { return new Workspace(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HomeInboxRow implements WireValue {
    private final String activityAt;
    private final Field<String> chief;
    private final Field<HomeChiefState> chiefState;
    private final String id;
    private final HomeInboxKind kind;
    private final Field<String> lastAuthor;
    private final boolean markedUnread;
    private final boolean muted;
    private final String name;
    private final String owner;
    private final Field<UInt64> pinPosition;
    private final boolean pinned;
    private final Field<String> preview;
    private final UInt64 unread;

    private HomeInboxRow(Builder builder) {
        if (!builder.activityAtSet) throw new IllegalArgumentException("activity_at is required");
        this.activityAt = Wire.nonNull(builder.activityAt, "activity_at");
        this.chief = builder.chief;
        this.chiefState = builder.chiefState;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.lastAuthor = builder.lastAuthor;
        if (!builder.markedUnreadSet) throw new IllegalArgumentException("marked_unread is required");
        this.markedUnread = builder.markedUnread;
        if (!builder.mutedSet) throw new IllegalArgumentException("muted is required");
        this.muted = builder.muted;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.ownerSet) throw new IllegalArgumentException("owner is required");
        this.owner = Wire.nonNull(builder.owner, "owner");
        this.pinPosition = builder.pinPosition;
        if (!builder.pinnedSet) throw new IllegalArgumentException("pinned is required");
        this.pinned = builder.pinned;
        this.preview = builder.preview;
        if (!builder.unreadSet) throw new IllegalArgumentException("unread is required");
        this.unread = Wire.nonNull(builder.unread, "unread");
    }

    public static Builder builder() { return new Builder(); }

    public String activityAt() { return activityAt; }
    public Field<String> chief() { return chief; }
    public Field<HomeChiefState> chiefState() { return chiefState; }
    public String id() { return id; }
    public HomeInboxKind kind() { return kind; }
    public Field<String> lastAuthor() { return lastAuthor; }
    public boolean markedUnread() { return markedUnread; }
    public boolean muted() { return muted; }
    public String name() { return name; }
    public String owner() { return owner; }
    public Field<UInt64> pinPosition() { return pinPosition; }
    public boolean pinned() { return pinned; }
    public Field<String> preview() { return preview; }
    public UInt64 unread() { return unread; }

    public static HomeInboxRow fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeInboxRow");
        Builder builder = builder();
        Object rawActivityAt = Wire.required(object, "activity_at");
        builder.activityAt(Wire.string(rawActivityAt, "HomeInboxRow.activity_at"));
        Object rawChief = Wire.optional(object, "chief");
        if (!Wire.isMissing(rawChief)) {
            builder.chief(Wire.string(rawChief, "HomeInboxRow.chief"));
        }
        Object rawChiefState = Wire.optional(object, "chief_state");
        if (!Wire.isMissing(rawChiefState)) {
            builder.chiefState(HomeChiefState.fromWire(rawChiefState));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "HomeInboxRow.id"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(HomeInboxKind.fromWire(rawKind));
        Object rawLastAuthor = Wire.optional(object, "last_author");
        if (!Wire.isMissing(rawLastAuthor)) {
            builder.lastAuthor(Wire.string(rawLastAuthor, "HomeInboxRow.last_author"));
        }
        Object rawMarkedUnread = Wire.required(object, "marked_unread");
        builder.markedUnread(Wire.bool(rawMarkedUnread, "HomeInboxRow.marked_unread"));
        Object rawMuted = Wire.required(object, "muted");
        builder.muted(Wire.bool(rawMuted, "HomeInboxRow.muted"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "HomeInboxRow.name"));
        Object rawOwner = Wire.required(object, "owner");
        builder.owner(Wire.string(rawOwner, "HomeInboxRow.owner"));
        Object rawPinPosition = Wire.optional(object, "pin_position");
        if (!Wire.isMissing(rawPinPosition)) {
            builder.pinPosition(Wire.uint64(rawPinPosition, "HomeInboxRow.pin_position"));
        }
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "HomeInboxRow.pinned"));
        Object rawPreview = Wire.optional(object, "preview");
        if (!Wire.isMissing(rawPreview)) {
            builder.preview(Wire.string(rawPreview, "HomeInboxRow.preview"));
        }
        Object rawUnread = Wire.required(object, "unread");
        builder.unread(Wire.uint64(rawUnread, "HomeInboxRow.unread"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activity_at", activityAt);
        Wire.put(object, "chief", chief);
        Wire.put(object, "chief_state", chiefState);
        Wire.put(object, "id", id);
        Wire.put(object, "kind", kind);
        Wire.put(object, "last_author", lastAuthor);
        Wire.put(object, "marked_unread", markedUnread);
        Wire.put(object, "muted", muted);
        Wire.put(object, "name", name);
        Wire.put(object, "owner", owner);
        Wire.put(object, "pin_position", pinPosition);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "preview", preview);
        Wire.put(object, "unread", unread);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeInboxRow that)) return false;
        return Objects.equals(activityAt, that.activityAt) && Objects.equals(chief, that.chief) && Objects.equals(chiefState, that.chiefState) && Objects.equals(id, that.id) && Objects.equals(kind, that.kind) && Objects.equals(lastAuthor, that.lastAuthor) && Objects.equals(markedUnread, that.markedUnread) && Objects.equals(muted, that.muted) && Objects.equals(name, that.name) && Objects.equals(owner, that.owner) && Objects.equals(pinPosition, that.pinPosition) && Objects.equals(pinned, that.pinned) && Objects.equals(preview, that.preview) && Objects.equals(unread, that.unread);
    }

    @Override
    public int hashCode() { return Objects.hash(activityAt, chief, chiefState, id, kind, lastAuthor, markedUnread, muted, name, owner, pinPosition, pinned, preview, unread); }

    @Override
    public String toString() { return "HomeInboxRow" + toWire(); }

    public static final class Builder {
        private String activityAt;
        private boolean activityAtSet;
        private Field<String> chief = Field.omitted();
        private Field<HomeChiefState> chiefState = Field.omitted();
        private String id;
        private boolean idSet;
        private HomeInboxKind kind;
        private boolean kindSet;
        private Field<String> lastAuthor = Field.omitted();
        private Boolean markedUnread;
        private boolean markedUnreadSet;
        private Boolean muted;
        private boolean mutedSet;
        private String name;
        private boolean nameSet;
        private String owner;
        private boolean ownerSet;
        private Field<UInt64> pinPosition = Field.omitted();
        private Boolean pinned;
        private boolean pinnedSet;
        private Field<String> preview = Field.omitted();
        private UInt64 unread;
        private boolean unreadSet;

        public Builder activityAt(String value) {
            this.activityAt = value;
            this.activityAtSet = true;
            return this;
        }
        public Builder chief(String value) {
            this.chief = Field.of(value);
            return this;
        }
        public Builder chiefState(HomeChiefState value) {
            this.chiefState = Field.of(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder kind(HomeInboxKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder lastAuthor(String value) {
            this.lastAuthor = Field.of(value);
            return this;
        }
        public Builder markedUnread(boolean value) {
            this.markedUnread = value;
            this.markedUnreadSet = true;
            return this;
        }
        public Builder muted(boolean value) {
            this.muted = value;
            this.mutedSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder owner(String value) {
            this.owner = value;
            this.ownerSet = true;
            return this;
        }
        public Builder pinPosition(UInt64 value) {
            this.pinPosition = Field.of(value);
            return this;
        }
        public Builder pinned(boolean value) {
            this.pinned = value;
            this.pinnedSet = true;
            return this;
        }
        public Builder preview(String value) {
            this.preview = Field.of(value);
            return this;
        }
        public Builder unread(UInt64 value) {
            this.unread = value;
            this.unreadSet = true;
            return this;
        }
        public HomeInboxRow build() { return new HomeInboxRow(this); }
    }
}

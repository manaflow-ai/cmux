// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable bookmarks-changed event. Protocol v12; streams: subscribe. */
public final class BookmarksChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 bookmarksRevision;
    private final String browserProfileId;

    private BookmarksChangedEvent(Builder builder) {
        if (!builder.bookmarksRevisionSet) throw new IllegalArgumentException("bookmarks_revision is required");
        this.bookmarksRevision = Wire.nonNull(builder.bookmarksRevision, "bookmarks_revision");
        if (!builder.browserProfileIdSet) throw new IllegalArgumentException("browser_profile_id is required");
        this.browserProfileId = Wire.nonNull(builder.browserProfileId, "browser_profile_id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bookmarksRevision() { return bookmarksRevision; }
    public String browserProfileId() { return browserProfileId; }
    @Override public String event() { return "bookmarks-changed"; }

    public static BookmarksChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BookmarksChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "bookmarks-changed", "BookmarksChangedEvent.event");
        Object rawBookmarksRevision = Wire.required(object, "bookmarks_revision");
        builder.bookmarksRevision(Wire.uint64(rawBookmarksRevision, "BookmarksChangedEvent.bookmarks_revision"));
        Object rawBrowserProfileId = Wire.required(object, "browser_profile_id");
        builder.browserProfileId(Wire.string(rawBrowserProfileId, "BookmarksChangedEvent.browser_profile_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "bookmarks-changed");
        Wire.put(object, "bookmarks_revision", bookmarksRevision);
        Wire.put(object, "browser_profile_id", browserProfileId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BookmarksChangedEvent that)) return false;
        return Objects.equals(bookmarksRevision, that.bookmarksRevision) && Objects.equals(browserProfileId, that.browserProfileId);
    }

    @Override
    public int hashCode() { return Objects.hash(bookmarksRevision, browserProfileId); }

    @Override
    public String toString() { return "BookmarksChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 bookmarksRevision;
        private boolean bookmarksRevisionSet;
        private String browserProfileId;
        private boolean browserProfileIdSet;

        public Builder bookmarksRevision(UInt64 value) {
            this.bookmarksRevision = value;
            this.bookmarksRevisionSet = true;
            return this;
        }
        public Builder browserProfileId(String value) {
            this.browserProfileId = value;
            this.browserProfileIdSet = true;
            return this;
        }
        public BookmarksChangedEvent build() { return new BookmarksChangedEvent(this); }
    }
}

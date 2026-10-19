// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientAttentionTab implements WireValue {
    /** Some connected client has its app active (cmux-next appActive). */
    private final boolean appActive;
    /** The pane that holds the tab now; null when the tab is not in the tree. */
    private final UInt64 pane;
    private final UInt64 surface;
    /** The newest keystroke in the tab over all clients (cmux-next typedAgo); null when unknown. */
    private final UInt64 typedMsAgo;
    /** The clock zone for quiet hours: the newest report that has one, a client whose app is active first. */
    private final Integer utcOffsetMinutes;
    /** Some client shows the tab as the focused content of its key window while its app is active (cmux-next paneIsViewed). */
    private final boolean viewed;

    private ClientAttentionTab(Builder builder) {
        if (!builder.appActiveSet) throw new IllegalArgumentException("app_active is required");
        this.appActive = builder.appActive;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.typedMsAgoSet) throw new IllegalArgumentException("typed_ms_ago is required");
        this.typedMsAgo = builder.typedMsAgo;
        if (!builder.utcOffsetMinutesSet) throw new IllegalArgumentException("utc_offset_minutes is required");
        this.utcOffsetMinutes = builder.utcOffsetMinutes;
        if (!builder.viewedSet) throw new IllegalArgumentException("viewed is required");
        this.viewed = builder.viewed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean appActive() { return appActive; }
    public UInt64 pane() { return pane; }
    public UInt64 surface() { return surface; }
    public UInt64 typedMsAgo() { return typedMsAgo; }
    public Integer utcOffsetMinutes() { return utcOffsetMinutes; }
    public boolean viewed() { return viewed; }

    public static ClientAttentionTab fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttentionTab");
        Builder builder = builder();
        Object rawAppActive = Wire.required(object, "app_active");
        builder.appActive(Wire.bool(rawAppActive, "ClientAttentionTab.app_active"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ClientAttentionTab.pane"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ClientAttentionTab.surface"));
        Object rawTypedMsAgo = Wire.required(object, "typed_ms_ago");
        builder.typedMsAgo(rawTypedMsAgo == null ? null : Wire.uint64(rawTypedMsAgo, "ClientAttentionTab.typed_ms_ago"));
        Object rawUtcOffsetMinutes = Wire.required(object, "utc_offset_minutes");
        builder.utcOffsetMinutes(rawUtcOffsetMinutes == null ? null : Wire.int32(rawUtcOffsetMinutes, "ClientAttentionTab.utc_offset_minutes"));
        Object rawViewed = Wire.required(object, "viewed");
        builder.viewed(Wire.bool(rawViewed, "ClientAttentionTab.viewed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "pane", pane);
        Wire.put(object, "surface", surface);
        Wire.put(object, "typed_ms_ago", typedMsAgo);
        Wire.put(object, "utc_offset_minutes", utcOffsetMinutes);
        Wire.put(object, "viewed", viewed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionTab that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(pane, that.pane) && Objects.equals(surface, that.surface) && Objects.equals(typedMsAgo, that.typedMsAgo) && Objects.equals(utcOffsetMinutes, that.utcOffsetMinutes) && Objects.equals(viewed, that.viewed);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, pane, surface, typedMsAgo, utcOffsetMinutes, viewed); }

    @Override
    public String toString() { return "ClientAttentionTab" + toWire(); }

    public static final class Builder {
        private Boolean appActive;
        private boolean appActiveSet;
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private UInt64 typedMsAgo;
        private boolean typedMsAgoSet;
        private Integer utcOffsetMinutes;
        private boolean utcOffsetMinutesSet;
        private Boolean viewed;
        private boolean viewedSet;

        public Builder appActive(boolean value) {
            this.appActive = value;
            this.appActiveSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder typedMsAgo(UInt64 value) {
            this.typedMsAgo = value;
            this.typedMsAgoSet = true;
            return this;
        }
        public Builder utcOffsetMinutes(Integer value) {
            this.utcOffsetMinutes = value;
            this.utcOffsetMinutesSet = true;
            return this;
        }
        public Builder viewed(boolean value) {
            this.viewed = value;
            this.viewedSet = true;
            return this;
        }
        public ClientAttentionTab build() { return new ClientAttentionTab(this); }
    }
}

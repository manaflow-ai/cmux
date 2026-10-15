// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientAttentionPane implements WireValue {
    /** Some client that focuses the pane has its app active. */
    private final boolean appActive;
    /** The newest input in a client that focuses the pane; null when unknown. */
    private final UInt64 lastInputMsAgo;
    private final UInt64 pane;
    /** Some client shows the pane as the focused pane of its key window while its app is active. */
    private final boolean viewed;

    private ClientAttentionPane(Builder builder) {
        if (!builder.appActiveSet) throw new IllegalArgumentException("app_active is required");
        this.appActive = builder.appActive;
        if (!builder.lastInputMsAgoSet) throw new IllegalArgumentException("last_input_ms_ago is required");
        this.lastInputMsAgo = builder.lastInputMsAgo;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.viewedSet) throw new IllegalArgumentException("viewed is required");
        this.viewed = builder.viewed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean appActive() { return appActive; }
    public UInt64 lastInputMsAgo() { return lastInputMsAgo; }
    public UInt64 pane() { return pane; }
    public boolean viewed() { return viewed; }

    public static ClientAttentionPane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttentionPane");
        Builder builder = builder();
        Object rawAppActive = Wire.required(object, "app_active");
        builder.appActive(Wire.bool(rawAppActive, "ClientAttentionPane.app_active"));
        Object rawLastInputMsAgo = Wire.required(object, "last_input_ms_ago");
        builder.lastInputMsAgo(rawLastInputMsAgo == null ? null : Wire.uint64(rawLastInputMsAgo, "ClientAttentionPane.last_input_ms_ago"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "ClientAttentionPane.pane"));
        Object rawViewed = Wire.required(object, "viewed");
        builder.viewed(Wire.bool(rawViewed, "ClientAttentionPane.viewed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "last_input_ms_ago", lastInputMsAgo);
        Wire.put(object, "pane", pane);
        Wire.put(object, "viewed", viewed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionPane that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(lastInputMsAgo, that.lastInputMsAgo) && Objects.equals(pane, that.pane) && Objects.equals(viewed, that.viewed);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, lastInputMsAgo, pane, viewed); }

    @Override
    public String toString() { return "ClientAttentionPane" + toWire(); }

    public static final class Builder {
        private Boolean appActive;
        private boolean appActiveSet;
        private UInt64 lastInputMsAgo;
        private boolean lastInputMsAgoSet;
        private UInt64 pane;
        private boolean paneSet;
        private Boolean viewed;
        private boolean viewedSet;

        public Builder appActive(boolean value) {
            this.appActive = value;
            this.appActiveSet = true;
            return this;
        }
        public Builder lastInputMsAgo(UInt64 value) {
            this.lastInputMsAgo = value;
            this.lastInputMsAgoSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder viewed(boolean value) {
            this.viewed = value;
            this.viewedSet = true;
            return this;
        }
        public ClientAttentionPane build() { return new ClientAttentionPane(this); }
    }
}

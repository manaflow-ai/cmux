// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientAttentionRecord implements WireValue {
    private final boolean appActive;
    private final String clientId;
    /** The daemon's id of the reporting connection. */
    private final UInt64 connection;
    private final boolean keyWindow;
    /** Null when the client reported none or the pane closed since. */
    private final UInt64 pane;
    /** Counted at read time from the report. */
    private final List<ClientAttentionInput> recentInput;
    private final UInt64 reportedMsAgo;
    /** Null when the client reported none or the pane closed since. */
    private final UInt64 tab;
    /** The client's clock zone; null when it reported none. */
    private final Integer utcOffsetMinutes;

    private ClientAttentionRecord(Builder builder) {
        if (!builder.appActiveSet) throw new IllegalArgumentException("app_active is required");
        this.appActive = builder.appActive;
        if (!builder.clientIdSet) throw new IllegalArgumentException("client_id is required");
        this.clientId = Wire.nonNull(builder.clientId, "client_id");
        if (!builder.connectionSet) throw new IllegalArgumentException("connection is required");
        this.connection = Wire.nonNull(builder.connection, "connection");
        if (!builder.keyWindowSet) throw new IllegalArgumentException("key_window is required");
        this.keyWindow = builder.keyWindow;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
        if (!builder.recentInputSet) throw new IllegalArgumentException("recent_input is required");
        this.recentInput = List.copyOf(Wire.nonNull(builder.recentInput, "recent_input"));
        if (!builder.reportedMsAgoSet) throw new IllegalArgumentException("reported_ms_ago is required");
        this.reportedMsAgo = Wire.nonNull(builder.reportedMsAgo, "reported_ms_ago");
        if (!builder.tabSet) throw new IllegalArgumentException("tab is required");
        this.tab = builder.tab;
        if (!builder.utcOffsetMinutesSet) throw new IllegalArgumentException("utc_offset_minutes is required");
        this.utcOffsetMinutes = builder.utcOffsetMinutes;
    }

    public static Builder builder() { return new Builder(); }

    public boolean appActive() { return appActive; }
    public String clientId() { return clientId; }
    public UInt64 connection() { return connection; }
    public boolean keyWindow() { return keyWindow; }
    public UInt64 pane() { return pane; }
    public List<ClientAttentionInput> recentInput() { return recentInput; }
    public UInt64 reportedMsAgo() { return reportedMsAgo; }
    public UInt64 tab() { return tab; }
    public Integer utcOffsetMinutes() { return utcOffsetMinutes; }

    public static ClientAttentionRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttentionRecord");
        Builder builder = builder();
        Object rawAppActive = Wire.required(object, "app_active");
        builder.appActive(Wire.bool(rawAppActive, "ClientAttentionRecord.app_active"));
        Object rawClientId = Wire.required(object, "client_id");
        builder.clientId(Wire.string(rawClientId, "ClientAttentionRecord.client_id"));
        Object rawConnection = Wire.required(object, "connection");
        builder.connection(Wire.uint64(rawConnection, "ClientAttentionRecord.connection"));
        Object rawKeyWindow = Wire.required(object, "key_window");
        builder.keyWindow(Wire.bool(rawKeyWindow, "ClientAttentionRecord.key_window"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ClientAttentionRecord.pane"));
        Object rawRecentInput = Wire.required(object, "recent_input");
        builder.recentInput(Wire.array(rawRecentInput, "ClientAttentionRecord.recent_input", item -> ClientAttentionInput.fromWire(item)));
        Object rawReportedMsAgo = Wire.required(object, "reported_ms_ago");
        builder.reportedMsAgo(Wire.uint64(rawReportedMsAgo, "ClientAttentionRecord.reported_ms_ago"));
        Object rawTab = Wire.required(object, "tab");
        builder.tab(rawTab == null ? null : Wire.uint64(rawTab, "ClientAttentionRecord.tab"));
        Object rawUtcOffsetMinutes = Wire.required(object, "utc_offset_minutes");
        builder.utcOffsetMinutes(rawUtcOffsetMinutes == null ? null : Wire.int32(rawUtcOffsetMinutes, "ClientAttentionRecord.utc_offset_minutes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "client_id", clientId);
        Wire.put(object, "connection", connection);
        Wire.put(object, "key_window", keyWindow);
        Wire.put(object, "pane", pane);
        Wire.put(object, "recent_input", recentInput);
        Wire.put(object, "reported_ms_ago", reportedMsAgo);
        Wire.put(object, "tab", tab);
        Wire.put(object, "utc_offset_minutes", utcOffsetMinutes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionRecord that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(clientId, that.clientId) && Objects.equals(connection, that.connection) && Objects.equals(keyWindow, that.keyWindow) && Objects.equals(pane, that.pane) && Objects.equals(recentInput, that.recentInput) && Objects.equals(reportedMsAgo, that.reportedMsAgo) && Objects.equals(tab, that.tab) && Objects.equals(utcOffsetMinutes, that.utcOffsetMinutes);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, clientId, connection, keyWindow, pane, recentInput, reportedMsAgo, tab, utcOffsetMinutes); }

    @Override
    public String toString() { return "ClientAttentionRecord" + toWire(); }

    public static final class Builder {
        private Boolean appActive;
        private boolean appActiveSet;
        private String clientId;
        private boolean clientIdSet;
        private UInt64 connection;
        private boolean connectionSet;
        private Boolean keyWindow;
        private boolean keyWindowSet;
        private UInt64 pane;
        private boolean paneSet;
        private List<ClientAttentionInput> recentInput;
        private boolean recentInputSet;
        private UInt64 reportedMsAgo;
        private boolean reportedMsAgoSet;
        private UInt64 tab;
        private boolean tabSet;
        private Integer utcOffsetMinutes;
        private boolean utcOffsetMinutesSet;

        public Builder appActive(boolean value) {
            this.appActive = value;
            this.appActiveSet = true;
            return this;
        }
        public Builder clientId(String value) {
            this.clientId = value;
            this.clientIdSet = true;
            return this;
        }
        public Builder connection(UInt64 value) {
            this.connection = value;
            this.connectionSet = true;
            return this;
        }
        public Builder keyWindow(boolean value) {
            this.keyWindow = value;
            this.keyWindowSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder recentInput(List<ClientAttentionInput> value) {
            this.recentInput = value;
            this.recentInputSet = true;
            return this;
        }
        public Builder reportedMsAgo(UInt64 value) {
            this.reportedMsAgo = value;
            this.reportedMsAgoSet = true;
            return this;
        }
        public Builder tab(UInt64 value) {
            this.tab = value;
            this.tabSet = true;
            return this;
        }
        public Builder utcOffsetMinutes(Integer value) {
            this.utcOffsetMinutes = value;
            this.utcOffsetMinutesSet = true;
            return this;
        }
        public ClientAttentionRecord build() { return new ClientAttentionRecord(this); }
    }
}

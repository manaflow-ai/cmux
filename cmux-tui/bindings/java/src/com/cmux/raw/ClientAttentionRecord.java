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
    /** Counted at read time from the report; null when unknown. */
    private final UInt64 lastInputMsAgo;
    /** Null when the client reported none or the pane closed since. */
    private final UInt64 pane;
    private final UInt64 reportedMsAgo;
    /** Null when the client reported none or the pane closed since. */
    private final UInt64 tab;

    private ClientAttentionRecord(Builder builder) {
        if (!builder.appActiveSet) throw new IllegalArgumentException("app_active is required");
        this.appActive = builder.appActive;
        if (!builder.clientIdSet) throw new IllegalArgumentException("client_id is required");
        this.clientId = Wire.nonNull(builder.clientId, "client_id");
        if (!builder.connectionSet) throw new IllegalArgumentException("connection is required");
        this.connection = Wire.nonNull(builder.connection, "connection");
        if (!builder.keyWindowSet) throw new IllegalArgumentException("key_window is required");
        this.keyWindow = builder.keyWindow;
        if (!builder.lastInputMsAgoSet) throw new IllegalArgumentException("last_input_ms_ago is required");
        this.lastInputMsAgo = builder.lastInputMsAgo;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
        if (!builder.reportedMsAgoSet) throw new IllegalArgumentException("reported_ms_ago is required");
        this.reportedMsAgo = Wire.nonNull(builder.reportedMsAgo, "reported_ms_ago");
        if (!builder.tabSet) throw new IllegalArgumentException("tab is required");
        this.tab = builder.tab;
    }

    public static Builder builder() { return new Builder(); }

    public boolean appActive() { return appActive; }
    public String clientId() { return clientId; }
    public UInt64 connection() { return connection; }
    public boolean keyWindow() { return keyWindow; }
    public UInt64 lastInputMsAgo() { return lastInputMsAgo; }
    public UInt64 pane() { return pane; }
    public UInt64 reportedMsAgo() { return reportedMsAgo; }
    public UInt64 tab() { return tab; }

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
        Object rawLastInputMsAgo = Wire.required(object, "last_input_ms_ago");
        builder.lastInputMsAgo(rawLastInputMsAgo == null ? null : Wire.uint64(rawLastInputMsAgo, "ClientAttentionRecord.last_input_ms_ago"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ClientAttentionRecord.pane"));
        Object rawReportedMsAgo = Wire.required(object, "reported_ms_ago");
        builder.reportedMsAgo(Wire.uint64(rawReportedMsAgo, "ClientAttentionRecord.reported_ms_ago"));
        Object rawTab = Wire.required(object, "tab");
        builder.tab(rawTab == null ? null : Wire.uint64(rawTab, "ClientAttentionRecord.tab"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "client_id", clientId);
        Wire.put(object, "connection", connection);
        Wire.put(object, "key_window", keyWindow);
        Wire.put(object, "last_input_ms_ago", lastInputMsAgo);
        Wire.put(object, "pane", pane);
        Wire.put(object, "reported_ms_ago", reportedMsAgo);
        Wire.put(object, "tab", tab);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionRecord that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(clientId, that.clientId) && Objects.equals(connection, that.connection) && Objects.equals(keyWindow, that.keyWindow) && Objects.equals(lastInputMsAgo, that.lastInputMsAgo) && Objects.equals(pane, that.pane) && Objects.equals(reportedMsAgo, that.reportedMsAgo) && Objects.equals(tab, that.tab);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, clientId, connection, keyWindow, lastInputMsAgo, pane, reportedMsAgo, tab); }

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
        private UInt64 lastInputMsAgo;
        private boolean lastInputMsAgoSet;
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 reportedMsAgo;
        private boolean reportedMsAgoSet;
        private UInt64 tab;
        private boolean tabSet;

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
        public ClientAttentionRecord build() { return new ClientAttentionRecord(this); }
    }
}

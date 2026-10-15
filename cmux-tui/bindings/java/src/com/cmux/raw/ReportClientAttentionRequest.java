// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable report-client-attention request. Protocol v12; authority: control. */
public final class ReportClientAttentionRequest implements WireValue {
    /** The client app is the active app; null or absent means the value of key_window. */
    private final Field<Boolean> appActive;
    private final String clientId;
    /** A window of this client is the key window of the OS. */
    private final boolean keyWindow;
    /** Milliseconds since the last key or pointer input in this client; null when unknown. */
    private final Field<UInt64> lastInputMsAgo;
    /** The focused pane of the client's key window, if any. */
    private final Field<UInt64> pane;
    /** The focused tab index within pane; needs pane. */
    private final Field<UInt64> tab;

    private ReportClientAttentionRequest(Builder builder) {
        this.appActive = builder.appActive;
        if (!builder.clientIdSet) throw new IllegalArgumentException("client_id is required");
        this.clientId = Wire.nonNull(builder.clientId, "client_id");
        if (!builder.keyWindowSet) throw new IllegalArgumentException("key_window is required");
        this.keyWindow = builder.keyWindow;
        this.lastInputMsAgo = builder.lastInputMsAgo;
        this.pane = builder.pane;
        this.tab = builder.tab;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> appActive() { return appActive; }
    public String clientId() { return clientId; }
    public boolean keyWindow() { return keyWindow; }
    public Field<UInt64> lastInputMsAgo() { return lastInputMsAgo; }
    public Field<UInt64> pane() { return pane; }
    public Field<UInt64> tab() { return tab; }

    public static ReportClientAttentionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportClientAttentionRequest");
        Builder builder = builder();
        Object rawAppActive = Wire.optional(object, "app_active");
        if (!Wire.isMissing(rawAppActive)) {
            builder.appActive(rawAppActive == null ? null : Wire.bool(rawAppActive, "ReportClientAttentionRequest.app_active"));
        }
        Object rawClientId = Wire.required(object, "client_id");
        builder.clientId(Wire.string(rawClientId, "ReportClientAttentionRequest.client_id"));
        Object rawKeyWindow = Wire.required(object, "key_window");
        builder.keyWindow(Wire.bool(rawKeyWindow, "ReportClientAttentionRequest.key_window"));
        Object rawLastInputMsAgo = Wire.optional(object, "last_input_ms_ago");
        if (!Wire.isMissing(rawLastInputMsAgo)) {
            builder.lastInputMsAgo(rawLastInputMsAgo == null ? null : Wire.uint64(rawLastInputMsAgo, "ReportClientAttentionRequest.last_input_ms_ago"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ReportClientAttentionRequest.pane"));
        }
        Object rawTab = Wire.optional(object, "tab");
        if (!Wire.isMissing(rawTab)) {
            builder.tab(rawTab == null ? null : Wire.uint64(rawTab, "ReportClientAttentionRequest.tab"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "client_id", clientId);
        Wire.put(object, "key_window", keyWindow);
        Wire.put(object, "last_input_ms_ago", lastInputMsAgo);
        Wire.put(object, "pane", pane);
        Wire.put(object, "tab", tab);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportClientAttentionRequest that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(clientId, that.clientId) && Objects.equals(keyWindow, that.keyWindow) && Objects.equals(lastInputMsAgo, that.lastInputMsAgo) && Objects.equals(pane, that.pane) && Objects.equals(tab, that.tab);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, clientId, keyWindow, lastInputMsAgo, pane, tab); }

    @Override
    public String toString() { return "ReportClientAttentionRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> appActive = Field.omitted();
        private String clientId;
        private boolean clientIdSet;
        private Boolean keyWindow;
        private boolean keyWindowSet;
        private Field<UInt64> lastInputMsAgo = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<UInt64> tab = Field.omitted();

        public Builder appActive(Boolean value) {
            this.appActive = Field.ofNullable(value);
            return this;
        }
        public Builder clientId(String value) {
            this.clientId = value;
            this.clientIdSet = true;
            return this;
        }
        public Builder keyWindow(boolean value) {
            this.keyWindow = value;
            this.keyWindowSet = true;
            return this;
        }
        public Builder lastInputMsAgo(UInt64 value) {
            this.lastInputMsAgo = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder tab(UInt64 value) {
            this.tab = Field.ofNullable(value);
            return this;
        }
        public ReportClientAttentionRequest build() { return new ReportClientAttentionRequest(this); }
    }
}

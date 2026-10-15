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
    /** The client app is the active app. */
    private final boolean appActive;
    private final String clientId;
    /** A window of this client is the key window of the OS. */
    private final boolean keyWindow;
    /** The focused pane of the client's key window, if any. */
    private final Field<UInt64> pane;
    /** The tabs the user typed in recently and how long ago, newest per tab (cmux-next tracks typing per tab). Replaces the whole list of the previous report. */
    private final Field<List<ClientAttentionInput>> recentInput;
    /** The focused tab index within pane; needs pane. */
    private final Field<UInt64> tab;
    /** Minutes east of UTC of the client's clock zone, for quiet hours. */
    private final Field<Integer> utcOffsetMinutes;

    private ReportClientAttentionRequest(Builder builder) {
        if (!builder.appActiveSet) throw new IllegalArgumentException("app_active is required");
        this.appActive = builder.appActive;
        if (!builder.clientIdSet) throw new IllegalArgumentException("client_id is required");
        this.clientId = Wire.nonNull(builder.clientId, "client_id");
        if (!builder.keyWindowSet) throw new IllegalArgumentException("key_window is required");
        this.keyWindow = builder.keyWindow;
        this.pane = builder.pane;
        this.recentInput = builder.recentInput.map(value -> List.copyOf(value));
        this.tab = builder.tab;
        this.utcOffsetMinutes = builder.utcOffsetMinutes;
    }

    public static Builder builder() { return new Builder(); }

    public boolean appActive() { return appActive; }
    public String clientId() { return clientId; }
    public boolean keyWindow() { return keyWindow; }
    public Field<UInt64> pane() { return pane; }
    public Field<List<ClientAttentionInput>> recentInput() { return recentInput; }
    public Field<UInt64> tab() { return tab; }
    public Field<Integer> utcOffsetMinutes() { return utcOffsetMinutes; }

    public static ReportClientAttentionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportClientAttentionRequest");
        Builder builder = builder();
        Object rawAppActive = Wire.required(object, "app_active");
        builder.appActive(Wire.bool(rawAppActive, "ReportClientAttentionRequest.app_active"));
        Object rawClientId = Wire.required(object, "client_id");
        builder.clientId(Wire.string(rawClientId, "ReportClientAttentionRequest.client_id"));
        Object rawKeyWindow = Wire.required(object, "key_window");
        builder.keyWindow(Wire.bool(rawKeyWindow, "ReportClientAttentionRequest.key_window"));
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ReportClientAttentionRequest.pane"));
        }
        Object rawRecentInput = Wire.optional(object, "recent_input");
        if (!Wire.isMissing(rawRecentInput)) {
            builder.recentInput(Wire.array(rawRecentInput, "ReportClientAttentionRequest.recent_input", item -> ClientAttentionInput.fromWire(item)));
        }
        Object rawTab = Wire.optional(object, "tab");
        if (!Wire.isMissing(rawTab)) {
            builder.tab(rawTab == null ? null : Wire.uint64(rawTab, "ReportClientAttentionRequest.tab"));
        }
        Object rawUtcOffsetMinutes = Wire.optional(object, "utc_offset_minutes");
        if (!Wire.isMissing(rawUtcOffsetMinutes)) {
            builder.utcOffsetMinutes(rawUtcOffsetMinutes == null ? null : Wire.int32(rawUtcOffsetMinutes, "ReportClientAttentionRequest.utc_offset_minutes"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "client_id", clientId);
        Wire.put(object, "key_window", keyWindow);
        Wire.put(object, "pane", pane);
        Wire.put(object, "recent_input", recentInput);
        Wire.put(object, "tab", tab);
        Wire.put(object, "utc_offset_minutes", utcOffsetMinutes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportClientAttentionRequest that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(clientId, that.clientId) && Objects.equals(keyWindow, that.keyWindow) && Objects.equals(pane, that.pane) && Objects.equals(recentInput, that.recentInput) && Objects.equals(tab, that.tab) && Objects.equals(utcOffsetMinutes, that.utcOffsetMinutes);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, clientId, keyWindow, pane, recentInput, tab, utcOffsetMinutes); }

    @Override
    public String toString() { return "ReportClientAttentionRequest" + toWire(); }

    public static final class Builder {
        private Boolean appActive;
        private boolean appActiveSet;
        private String clientId;
        private boolean clientIdSet;
        private Boolean keyWindow;
        private boolean keyWindowSet;
        private Field<UInt64> pane = Field.omitted();
        private Field<List<ClientAttentionInput>> recentInput = Field.omitted();
        private Field<UInt64> tab = Field.omitted();
        private Field<Integer> utcOffsetMinutes = Field.omitted();

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
        public Builder keyWindow(boolean value) {
            this.keyWindow = value;
            this.keyWindowSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder recentInput(List<ClientAttentionInput> value) {
            this.recentInput = Field.of(value);
            return this;
        }
        public Builder tab(UInt64 value) {
            this.tab = Field.ofNullable(value);
            return this;
        }
        public Builder utcOffsetMinutes(Integer value) {
            this.utcOffsetMinutes = Field.ofNullable(value);
            return this;
        }
        public ReportClientAttentionRequest build() { return new ReportClientAttentionRequest(this); }
    }
}

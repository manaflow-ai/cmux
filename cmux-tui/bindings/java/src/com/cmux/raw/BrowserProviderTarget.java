// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserProviderTarget implements WireValue {
    private final String tabId;
    private final String targetId;

    private BrowserProviderTarget(Builder builder) {
        if (!builder.tabIdSet) throw new IllegalArgumentException("tab_id is required");
        this.tabId = Wire.nonNull(builder.tabId, "tab_id");
        if (!builder.targetIdSet) throw new IllegalArgumentException("target_id is required");
        this.targetId = Wire.nonNull(builder.targetId, "target_id");
    }

    public static Builder builder() { return new Builder(); }

    public String tabId() { return tabId; }
    public String targetId() { return targetId; }

    public static BrowserProviderTarget fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserProviderTarget");
        Builder builder = builder();
        Object rawTabId = Wire.required(object, "tab_id");
        builder.tabId(Wire.string(rawTabId, "BrowserProviderTarget.tab_id"));
        Object rawTargetId = Wire.required(object, "target_id");
        builder.targetId(Wire.string(rawTargetId, "BrowserProviderTarget.target_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "tab_id", tabId);
        Wire.put(object, "target_id", targetId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserProviderTarget that)) return false;
        return Objects.equals(tabId, that.tabId) && Objects.equals(targetId, that.targetId);
    }

    @Override
    public int hashCode() { return Objects.hash(tabId, targetId); }

    @Override
    public String toString() { return "BrowserProviderTarget" + toWire(); }

    public static final class Builder {
        private String tabId;
        private boolean tabIdSet;
        private String targetId;
        private boolean targetIdSet;

        public Builder tabId(String value) {
            this.tabId = value;
            this.tabIdSet = true;
            return this;
        }
        public Builder targetId(String value) {
            this.targetId = value;
            this.targetIdSet = true;
            return this;
        }
        public BrowserProviderTarget build() { return new BrowserProviderTarget(this); }
    }
}

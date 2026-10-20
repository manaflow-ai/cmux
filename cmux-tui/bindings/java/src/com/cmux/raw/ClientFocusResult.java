// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientFocusResult implements WireValue {
    private final UInt64 pane;
    private final UInt64 tab;

    private ClientFocusResult(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
        if (!builder.tabSet) throw new IllegalArgumentException("tab is required");
        this.tab = builder.tab;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public UInt64 tab() { return tab; }

    public static ClientFocusResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientFocusResult");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ClientFocusResult.pane"));
        Object rawTab = Wire.required(object, "tab");
        builder.tab(rawTab == null ? null : Wire.uint64(rawTab, "ClientFocusResult.tab"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "tab", tab);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientFocusResult that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(tab, that.tab);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, tab); }

    @Override
    public String toString() { return "ClientFocusResult" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 tab;
        private boolean tabSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder tab(UInt64 value) {
            this.tab = value;
            this.tabSet = true;
            return this;
        }
        public ClientFocusResult build() { return new ClientFocusResult(this); }
    }
}

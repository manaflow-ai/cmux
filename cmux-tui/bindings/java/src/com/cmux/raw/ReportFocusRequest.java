// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable report-focus request. Protocol v12; authority: control. */
public final class ReportFocusRequest implements WireValue {
    private final String clientId;
    private final UInt64 pane;
    private final Field<UInt64> tab;

    private ReportFocusRequest(Builder builder) {
        if (!builder.clientIdSet) throw new IllegalArgumentException("client_id is required");
        this.clientId = Wire.nonNull(builder.clientId, "client_id");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.tab = builder.tab;
    }

    public static Builder builder() { return new Builder(); }

    public String clientId() { return clientId; }
    public UInt64 pane() { return pane; }
    public Field<UInt64> tab() { return tab; }

    public static ReportFocusRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportFocusRequest");
        Builder builder = builder();
        Object rawClientId = Wire.required(object, "client_id");
        builder.clientId(Wire.string(rawClientId, "ReportFocusRequest.client_id"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "ReportFocusRequest.pane"));
        Object rawTab = Wire.optional(object, "tab");
        if (!Wire.isMissing(rawTab)) {
            builder.tab(rawTab == null ? null : Wire.uint64(rawTab, "ReportFocusRequest.tab"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client_id", clientId);
        Wire.put(object, "pane", pane);
        Wire.put(object, "tab", tab);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportFocusRequest that)) return false;
        return Objects.equals(clientId, that.clientId) && Objects.equals(pane, that.pane) && Objects.equals(tab, that.tab);
    }

    @Override
    public int hashCode() { return Objects.hash(clientId, pane, tab); }

    @Override
    public String toString() { return "ReportFocusRequest" + toWire(); }

    public static final class Builder {
        private String clientId;
        private boolean clientIdSet;
        private UInt64 pane;
        private boolean paneSet;
        private Field<UInt64> tab = Field.omitted();

        public Builder clientId(String value) {
            this.clientId = value;
            this.clientIdSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder tab(UInt64 value) {
            this.tab = Field.ofNullable(value);
            return this;
        }
        public ReportFocusRequest build() { return new ReportFocusRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RequestFrontendBrowserTabCloseResult implements WireValue {
    /** True when the owner app was asked; false when the tab has no owner or the owner has no live subscribed connection, and nothing changed. */
    private final boolean delegated;
    /** Null when not delegated. A second request for the same tab joins the open one. */
    private final String requestId;

    private RequestFrontendBrowserTabCloseResult(Builder builder) {
        if (!builder.delegatedSet) throw new IllegalArgumentException("delegated is required");
        this.delegated = builder.delegated;
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = builder.requestId;
    }

    public static Builder builder() { return new Builder(); }

    public boolean delegated() { return delegated; }
    public String requestId() { return requestId; }

    public static RequestFrontendBrowserTabCloseResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RequestFrontendBrowserTabCloseResult");
        Builder builder = builder();
        Object rawDelegated = Wire.required(object, "delegated");
        builder.delegated(Wire.bool(rawDelegated, "RequestFrontendBrowserTabCloseResult.delegated"));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(rawRequestId == null ? null : Wire.string(rawRequestId, "RequestFrontendBrowserTabCloseResult.request_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "delegated", delegated);
        Wire.put(object, "request_id", requestId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RequestFrontendBrowserTabCloseResult that)) return false;
        return Objects.equals(delegated, that.delegated) && Objects.equals(requestId, that.requestId);
    }

    @Override
    public int hashCode() { return Objects.hash(delegated, requestId); }

    @Override
    public String toString() { return "RequestFrontendBrowserTabCloseResult" + toWire(); }

    public static final class Builder {
        private Boolean delegated;
        private boolean delegatedSet;
        private String requestId;
        private boolean requestIdSet;

        public Builder delegated(boolean value) {
            this.delegated = value;
            this.delegatedSet = true;
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public RequestFrontendBrowserTabCloseResult build() { return new RequestFrontendBrowserTabCloseResult(this); }
    }
}

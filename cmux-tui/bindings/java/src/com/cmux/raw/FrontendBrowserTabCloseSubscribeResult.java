// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FrontendBrowserTabCloseSubscribeResult implements WireValue {
    private final boolean closeRequestsReady;

    private FrontendBrowserTabCloseSubscribeResult(Builder builder) {
        if (!builder.closeRequestsReadySet) throw new IllegalArgumentException("close_requests_ready is required");
        this.closeRequestsReady = builder.closeRequestsReady;
    }

    public static Builder builder() { return new Builder(); }

    public boolean closeRequestsReady() { return closeRequestsReady; }

    public static FrontendBrowserTabCloseSubscribeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendBrowserTabCloseSubscribeResult");
        Builder builder = builder();
        Object rawCloseRequestsReady = Wire.required(object, "close_requests_ready");
        builder.closeRequestsReady(Wire.bool(rawCloseRequestsReady, "FrontendBrowserTabCloseSubscribeResult.close_requests_ready"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "close_requests_ready", closeRequestsReady);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendBrowserTabCloseSubscribeResult that)) return false;
        return Objects.equals(closeRequestsReady, that.closeRequestsReady);
    }

    @Override
    public int hashCode() { return Objects.hash(closeRequestsReady); }

    @Override
    public String toString() { return "FrontendBrowserTabCloseSubscribeResult" + toWire(); }

    public static final class Builder {
        private Boolean closeRequestsReady;
        private boolean closeRequestsReadySet;

        public Builder closeRequestsReady(boolean value) {
            this.closeRequestsReady = value;
            this.closeRequestsReadySet = true;
            return this;
        }
        public FrontendBrowserTabCloseSubscribeResult build() { return new FrontendBrowserTabCloseSubscribeResult(this); }
    }
}

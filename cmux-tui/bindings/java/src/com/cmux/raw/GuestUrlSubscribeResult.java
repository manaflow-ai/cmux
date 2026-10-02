// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GuestUrlSubscribeResult implements WireValue {
    private final boolean urlOpenReady;

    private GuestUrlSubscribeResult(Builder builder) {
        if (!builder.urlOpenReadySet) throw new IllegalArgumentException("url_open_ready is required");
        this.urlOpenReady = builder.urlOpenReady;
    }

    public static Builder builder() { return new Builder(); }

    public boolean urlOpenReady() { return urlOpenReady; }

    public static GuestUrlSubscribeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GuestUrlSubscribeResult");
        Builder builder = builder();
        Object rawUrlOpenReady = Wire.required(object, "url_open_ready");
        builder.urlOpenReady(Wire.bool(rawUrlOpenReady, "GuestUrlSubscribeResult.url_open_ready"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "url_open_ready", urlOpenReady);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GuestUrlSubscribeResult that)) return false;
        return Objects.equals(urlOpenReady, that.urlOpenReady);
    }

    @Override
    public int hashCode() { return Objects.hash(urlOpenReady); }

    @Override
    public String toString() { return "GuestUrlSubscribeResult" + toWire(); }

    public static final class Builder {
        private Boolean urlOpenReady;
        private boolean urlOpenReadySet;

        public Builder urlOpenReady(boolean value) {
            this.urlOpenReady = value;
            this.urlOpenReadySet = true;
            return this;
        }
        public GuestUrlSubscribeResult build() { return new GuestUrlSubscribeResult(this); }
    }
}

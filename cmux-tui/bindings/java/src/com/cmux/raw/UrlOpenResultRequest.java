// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable url-open-result request. Protocol v12; authority: frontend. */
public final class UrlOpenResultRequest implements WireValue {
    private final boolean opened;
    private final String requestId;

    private UrlOpenResultRequest(Builder builder) {
        if (!builder.openedSet) throw new IllegalArgumentException("opened is required");
        this.opened = builder.opened;
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
    }

    public static Builder builder() { return new Builder(); }

    public boolean opened() { return opened; }
    public String requestId() { return requestId; }

    public static UrlOpenResultRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UrlOpenResultRequest");
        Builder builder = builder();
        Object rawOpened = Wire.required(object, "opened");
        builder.opened(Wire.bool(rawOpened, "UrlOpenResultRequest.opened"));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "UrlOpenResultRequest.request_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "opened", opened);
        Wire.put(object, "request_id", requestId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UrlOpenResultRequest that)) return false;
        return Objects.equals(opened, that.opened) && Objects.equals(requestId, that.requestId);
    }

    @Override
    public int hashCode() { return Objects.hash(opened, requestId); }

    @Override
    public String toString() { return "UrlOpenResultRequest" + toWire(); }

    public static final class Builder {
        private Boolean opened;
        private boolean openedSet;
        private String requestId;
        private boolean requestIdSet;

        public Builder opened(boolean value) {
            this.opened = value;
            this.openedSet = true;
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public UrlOpenResultRequest build() { return new UrlOpenResultRequest(this); }
    }
}

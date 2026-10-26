// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AccessRequestResult implements WireValue {
    private final String requestId;

    private AccessRequestResult(Builder builder) {
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
    }

    public static Builder builder() { return new Builder(); }

    public String requestId() { return requestId; }

    public static AccessRequestResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestResult");
        Builder builder = builder();
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "AccessRequestResult.request_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "request_id", requestId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestResult that)) return false;
        return Objects.equals(requestId, that.requestId);
    }

    @Override
    public int hashCode() { return Objects.hash(requestId); }

    @Override
    public String toString() { return "AccessRequestResult" + toWire(); }

    public static final class Builder {
        private String requestId;
        private boolean requestIdSet;

        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public AccessRequestResult build() { return new AccessRequestResult(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AccessRequestListResult implements WireValue {
    private final List<AccessRequestPending> requests;

    private AccessRequestListResult(Builder builder) {
        if (!builder.requestsSet) throw new IllegalArgumentException("requests is required");
        this.requests = List.copyOf(Wire.nonNull(builder.requests, "requests"));
    }

    public static Builder builder() { return new Builder(); }

    public List<AccessRequestPending> requests() { return requests; }

    public static AccessRequestListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestListResult");
        Builder builder = builder();
        Object rawRequests = Wire.required(object, "requests");
        builder.requests(Wire.array(rawRequests, "AccessRequestListResult.requests", item -> AccessRequestPending.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "requests", requests);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestListResult that)) return false;
        return Objects.equals(requests, that.requests);
    }

    @Override
    public int hashCode() { return Objects.hash(requests); }

    @Override
    public String toString() { return "AccessRequestListResult" + toWire(); }

    public static final class Builder {
        private List<AccessRequestPending> requests;
        private boolean requestsSet;

        public Builder requests(List<AccessRequestPending> value) {
            this.requests = value;
            this.requestsSet = true;
            return this;
        }
        public AccessRequestListResult build() { return new AccessRequestListResult(this); }
    }
}

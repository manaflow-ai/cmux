// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AccessRequestStatusDenied implements WireValue, AccessRequestStatus {
    private final String reason;

    private AccessRequestStatusDenied(Builder builder) {
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = builder.reason;
    }

    public static Builder builder() { return new Builder(); }

    public String reason() { return reason; }
    public String state() { return "denied"; }

    public static AccessRequestStatusDenied fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestStatusDenied");
        Builder builder = builder();
        Object rawReason = Wire.required(object, "reason");
        builder.reason(rawReason == null ? null : Wire.string(rawReason, "AccessRequestStatusDenied.reason"));
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "denied", "AccessRequestStatusDenied.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "reason", reason);
        Wire.put(object, "state", "denied");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestStatusDenied that)) return false;
        return Objects.equals(reason, that.reason);
    }

    @Override
    public int hashCode() { return Objects.hash(reason); }

    @Override
    public String toString() { return "AccessRequestStatusDenied" + toWire(); }

    public static final class Builder {
        private String reason;
        private boolean reasonSet;

        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public AccessRequestStatusDenied build() { return new AccessRequestStatusDenied(this); }
    }
}

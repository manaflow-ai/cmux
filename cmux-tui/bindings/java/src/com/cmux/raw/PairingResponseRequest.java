// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable pairing-response request. Protocol v7; authority: local-admin. */
public final class PairingResponseRequest implements WireValue {
    private final boolean approve;
    private final UInt64 request;

    private PairingResponseRequest(Builder builder) {
        if (!builder.approveSet) throw new IllegalArgumentException("approve is required");
        this.approve = builder.approve;
        if (!builder.requestSet) throw new IllegalArgumentException("request is required");
        this.request = Wire.nonNull(builder.request, "request");
    }

    public static Builder builder() { return new Builder(); }

    public boolean approve() { return approve; }
    public UInt64 request() { return request; }

    public static PairingResponseRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PairingResponseRequest");
        Builder builder = builder();
        Object rawApprove = Wire.required(object, "approve");
        builder.approve(Wire.bool(rawApprove, "PairingResponseRequest.approve"));
        Object rawRequest = Wire.required(object, "request");
        builder.request(Wire.uint64(rawRequest, "PairingResponseRequest.request"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "approve", approve);
        Wire.put(object, "request", request);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PairingResponseRequest that)) return false;
        return Objects.equals(approve, that.approve) && Objects.equals(request, that.request);
    }

    @Override
    public int hashCode() { return Objects.hash(approve, request); }

    @Override
    public String toString() { return "PairingResponseRequest" + toWire(); }

    public static final class Builder {
        private Boolean approve;
        private boolean approveSet;
        private UInt64 request;
        private boolean requestSet;

        public Builder approve(boolean value) {
            this.approve = value;
            this.approveSet = true;
            return this;
        }
        public Builder request(UInt64 value) {
            this.request = value;
            this.requestSet = true;
            return this;
        }
        public PairingResponseRequest build() { return new PairingResponseRequest(this); }
    }
}

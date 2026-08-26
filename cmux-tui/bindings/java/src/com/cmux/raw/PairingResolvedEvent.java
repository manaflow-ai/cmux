// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable pairing-resolved event. Protocol v7; streams: subscribe. */
public final class PairingResolvedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 request;

    private PairingResolvedEvent(Builder builder) {
        if (!builder.requestSet) throw new IllegalArgumentException("request is required");
        this.request = Wire.nonNull(builder.request, "request");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 request() { return request; }
    @Override public String event() { return "pairing-resolved"; }

    public static PairingResolvedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PairingResolvedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "pairing-resolved", "PairingResolvedEvent.event");
        Object rawRequest = Wire.required(object, "request");
        builder.request(Wire.uint64(rawRequest, "PairingResolvedEvent.request"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "pairing-resolved");
        Wire.put(object, "request", request);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PairingResolvedEvent that)) return false;
        return Objects.equals(request, that.request);
    }

    @Override
    public int hashCode() { return Objects.hash(request); }

    @Override
    public String toString() { return "PairingResolvedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 request;
        private boolean requestSet;

        public Builder request(UInt64 value) {
            this.request = value;
            this.requestSet = true;
            return this;
        }
        public PairingResolvedEvent build() { return new PairingResolvedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable pairing-requested event. Protocol v7; streams: subscribe. */
public final class PairingRequestedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String code;
    private final UInt64 expiresIn;
    private final String peer;
    private final UInt64 request;

    private PairingRequestedEvent(Builder builder) {
        if (!builder.codeSet) throw new IllegalArgumentException("code is required");
        this.code = Wire.nonNull(builder.code, "code");
        if (!builder.expiresInSet) throw new IllegalArgumentException("expires_in is required");
        this.expiresIn = Wire.nonNull(builder.expiresIn, "expires_in");
        if (!builder.peerSet) throw new IllegalArgumentException("peer is required");
        this.peer = Wire.nonNull(builder.peer, "peer");
        if (!builder.requestSet) throw new IllegalArgumentException("request is required");
        this.request = Wire.nonNull(builder.request, "request");
    }

    public static Builder builder() { return new Builder(); }

    public String code() { return code; }
    public UInt64 expiresIn() { return expiresIn; }
    public String peer() { return peer; }
    public UInt64 request() { return request; }
    @Override public String event() { return "pairing-requested"; }

    public static PairingRequestedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PairingRequestedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "pairing-requested", "PairingRequestedEvent.event");
        Object rawCode = Wire.required(object, "code");
        builder.code(Wire.string(rawCode, "PairingRequestedEvent.code"));
        Object rawExpiresIn = Wire.required(object, "expires_in");
        builder.expiresIn(Wire.uint64(rawExpiresIn, "PairingRequestedEvent.expires_in"));
        Object rawPeer = Wire.required(object, "peer");
        builder.peer(Wire.string(rawPeer, "PairingRequestedEvent.peer"));
        Object rawRequest = Wire.required(object, "request");
        builder.request(Wire.uint64(rawRequest, "PairingRequestedEvent.request"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "pairing-requested");
        Wire.put(object, "code", code);
        Wire.put(object, "expires_in", expiresIn);
        Wire.put(object, "peer", peer);
        Wire.put(object, "request", request);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PairingRequestedEvent that)) return false;
        return Objects.equals(code, that.code) && Objects.equals(expiresIn, that.expiresIn) && Objects.equals(peer, that.peer) && Objects.equals(request, that.request);
    }

    @Override
    public int hashCode() { return Objects.hash(code, expiresIn, peer, request); }

    @Override
    public String toString() { return "PairingRequestedEvent" + toWire(); }

    public static final class Builder {
        private String code;
        private boolean codeSet;
        private UInt64 expiresIn;
        private boolean expiresInSet;
        private String peer;
        private boolean peerSet;
        private UInt64 request;
        private boolean requestSet;

        public Builder code(String value) {
            this.code = value;
            this.codeSet = true;
            return this;
        }
        public Builder expiresIn(UInt64 value) {
            this.expiresIn = value;
            this.expiresInSet = true;
            return this;
        }
        public Builder peer(String value) {
            this.peer = value;
            this.peerSet = true;
            return this;
        }
        public Builder request(UInt64 value) {
            this.request = value;
            this.requestSet = true;
            return this;
        }
        public PairingRequestedEvent build() { return new PairingRequestedEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-mux-resynced event. Protocol v12; streams: subscribe. */
public final class CloudMuxResyncedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    private final Object pending;
    private final UInt64 seq;

    private CloudMuxResyncedEvent(Builder builder) {
        this.account = builder.account;
        if (!builder.pendingSet) throw new IllegalArgumentException("pending is required");
        this.pending = builder.pending == null ? null : Wire.immutableJson(builder.pending);
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public Object pending() { return pending; }
    public UInt64 seq() { return seq; }
    @Override public String event() { return "cloud-mux-resynced"; }

    public static CloudMuxResyncedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudMuxResyncedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-mux-resynced", "CloudMuxResyncedEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudMuxResyncedEvent.account"));
        }
        Object rawPending = Wire.required(object, "pending");
        builder.pending(rawPending == null ? null : Wire.immutableJson(rawPending));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudMuxResyncedEvent.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-mux-resynced");
        Wire.put(object, "account", account);
        Wire.put(object, "pending", pending);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudMuxResyncedEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(pending, that.pending) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(account, pending, seq); }

    @Override
    public String toString() { return "CloudMuxResyncedEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private Object pending;
        private boolean pendingSet;
        private UInt64 seq;
        private boolean seqSet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder pending(Object value) {
            this.pending = value;
            this.pendingSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public CloudMuxResyncedEvent build() { return new CloudMuxResyncedEvent(this); }
    }
}

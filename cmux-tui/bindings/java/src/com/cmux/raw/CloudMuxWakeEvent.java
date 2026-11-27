// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-mux-wake event. Protocol v12; streams: subscribe. */
public final class CloudMuxWakeEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    private final UInt64 seq;
    private final Object wakes;

    private CloudMuxWakeEvent(Builder builder) {
        this.account = builder.account;
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.wakesSet) throw new IllegalArgumentException("wakes is required");
        this.wakes = builder.wakes == null ? null : Wire.immutableJson(builder.wakes);
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public UInt64 seq() { return seq; }
    public Object wakes() { return wakes; }
    @Override public String event() { return "cloud-mux-wake"; }

    public static CloudMuxWakeEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudMuxWakeEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-mux-wake", "CloudMuxWakeEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudMuxWakeEvent.account"));
        }
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudMuxWakeEvent.seq"));
        Object rawWakes = Wire.required(object, "wakes");
        builder.wakes(rawWakes == null ? null : Wire.immutableJson(rawWakes));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-mux-wake");
        Wire.put(object, "account", account);
        Wire.put(object, "seq", seq);
        Wire.put(object, "wakes", wakes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudMuxWakeEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(seq, that.seq) && Objects.equals(wakes, that.wakes);
    }

    @Override
    public int hashCode() { return Objects.hash(account, seq, wakes); }

    @Override
    public String toString() { return "CloudMuxWakeEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private UInt64 seq;
        private boolean seqSet;
        private Object wakes;
        private boolean wakesSet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder wakes(Object value) {
            this.wakes = value;
            this.wakesSet = true;
            return this;
        }
        public CloudMuxWakeEvent build() { return new CloudMuxWakeEvent(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-inbox-reset event. Protocol v12; streams: subscribe. */
public final class CloudInboxResetEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    private final UInt64 seq;

    private CloudInboxResetEvent(Builder builder) {
        this.account = builder.account;
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public UInt64 seq() { return seq; }
    @Override public String event() { return "cloud-inbox-reset"; }

    public static CloudInboxResetEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudInboxResetEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-inbox-reset", "CloudInboxResetEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudInboxResetEvent.account"));
        }
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudInboxResetEvent.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-inbox-reset");
        Wire.put(object, "account", account);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudInboxResetEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(account, seq); }

    @Override
    public String toString() { return "CloudInboxResetEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private UInt64 seq;
        private boolean seqSet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public CloudInboxResetEvent build() { return new CloudInboxResetEvent(this); }
    }
}

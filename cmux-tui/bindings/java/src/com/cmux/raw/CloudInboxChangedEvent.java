// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-inbox-changed event. Protocol v12; streams: subscribe. */
public final class CloudInboxChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> account;
    private final Object entries;
    private final UInt64 seq;
    private final String transaction;

    private CloudInboxChangedEvent(Builder builder) {
        this.account = builder.account;
        if (!builder.entriesSet) throw new IllegalArgumentException("entries is required");
        this.entries = builder.entries == null ? null : Wire.immutableJson(builder.entries);
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.transactionSet) throw new IllegalArgumentException("transaction is required");
        this.transaction = Wire.nonNull(builder.transaction, "transaction");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> account() { return account; }
    public Object entries() { return entries; }
    public UInt64 seq() { return seq; }
    public String transaction() { return transaction; }
    @Override public String event() { return "cloud-inbox-changed"; }

    public static CloudInboxChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudInboxChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-inbox-changed", "CloudInboxChangedEvent.event");
        Object rawAccount = Wire.optional(object, "account");
        if (!Wire.isMissing(rawAccount)) {
            builder.account(Wire.string(rawAccount, "CloudInboxChangedEvent.account"));
        }
        Object rawEntries = Wire.required(object, "entries");
        builder.entries(rawEntries == null ? null : Wire.immutableJson(rawEntries));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudInboxChangedEvent.seq"));
        Object rawTransaction = Wire.required(object, "transaction");
        builder.transaction(Wire.string(rawTransaction, "CloudInboxChangedEvent.transaction"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-inbox-changed");
        Wire.put(object, "account", account);
        Wire.put(object, "entries", entries);
        Wire.put(object, "seq", seq);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudInboxChangedEvent that)) return false;
        return Objects.equals(account, that.account) && Objects.equals(entries, that.entries) && Objects.equals(seq, that.seq) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(account, entries, seq, transaction); }

    @Override
    public String toString() { return "CloudInboxChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<String> account = Field.omitted();
        private Object entries;
        private boolean entriesSet;
        private UInt64 seq;
        private boolean seqSet;
        private String transaction;
        private boolean transactionSet;

        public Builder account(String value) {
            this.account = Field.of(value);
            return this;
        }
        public Builder entries(Object value) {
            this.entries = value;
            this.entriesSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = value;
            this.transactionSet = true;
            return this;
        }
        public CloudInboxChangedEvent build() { return new CloudInboxChangedEvent(this); }
    }
}

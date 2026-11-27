// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationOpResult implements WireValue {
    private final ConversationChange change;
    private final boolean replayed;
    private final UInt64 rev;
    private final Field<UInt64> seq;
    private final Field<String> transaction;

    private ConversationOpResult(Builder builder) {
        if (!builder.changeSet) throw new IllegalArgumentException("change is required");
        this.change = Wire.nonNull(builder.change, "change");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.revSet) throw new IllegalArgumentException("rev is required");
        this.rev = Wire.nonNull(builder.rev, "rev");
        this.seq = builder.seq;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public ConversationChange change() { return change; }
    public boolean replayed() { return replayed; }
    public UInt64 rev() { return rev; }
    public Field<UInt64> seq() { return seq; }
    public Field<String> transaction() { return transaction; }

    public static ConversationOpResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationOpResult");
        Builder builder = builder();
        Object rawChange = Wire.required(object, "change");
        builder.change(ConversationChange.fromWire(rawChange));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "ConversationOpResult.replayed"));
        Object rawRev = Wire.required(object, "rev");
        builder.rev(Wire.uint64(rawRev, "ConversationOpResult.rev"));
        Object rawSeq = Wire.optional(object, "seq");
        if (!Wire.isMissing(rawSeq)) {
            builder.seq(Wire.uint64(rawSeq, "ConversationOpResult.seq"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(Wire.string(rawTransaction, "ConversationOpResult.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "change", change);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "rev", rev);
        Wire.put(object, "seq", seq);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationOpResult that)) return false;
        return Objects.equals(change, that.change) && Objects.equals(replayed, that.replayed) && Objects.equals(rev, that.rev) && Objects.equals(seq, that.seq) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(change, replayed, rev, seq, transaction); }

    @Override
    public String toString() { return "ConversationOpResult" + toWire(); }

    public static final class Builder {
        private ConversationChange change;
        private boolean changeSet;
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 rev;
        private boolean revSet;
        private Field<UInt64> seq = Field.omitted();
        private Field<String> transaction = Field.omitted();

        public Builder change(ConversationChange value) {
            this.change = value;
            this.changeSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder rev(UInt64 value) {
            this.rev = value;
            this.revSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = Field.of(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.of(value);
            return this;
        }
        public ConversationOpResult build() { return new ConversationOpResult(this); }
    }
}

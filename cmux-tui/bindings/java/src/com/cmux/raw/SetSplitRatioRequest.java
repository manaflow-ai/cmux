// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-split-ratio request. Protocol v8; authority: control. */
public final class SetSplitRatioRequest implements WireValue {
    private final double ratio;
    private final UInt64 split;
    private final Field<UInt64> transaction;

    private SetSplitRatioRequest(Builder builder) {
        if (!builder.ratioSet) throw new IllegalArgumentException("ratio is required");
        this.ratio = builder.ratio;
        if (!builder.splitSet) throw new IllegalArgumentException("split is required");
        this.split = Wire.nonNull(builder.split, "split");
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public double ratio() { return ratio; }
    public UInt64 split() { return split; }
    public Field<UInt64> transaction() { return transaction; }

    public static SetSplitRatioRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetSplitRatioRequest");
        Builder builder = builder();
        Object rawRatio = Wire.required(object, "ratio");
        builder.ratio(Wire.float64(rawRatio, "SetSplitRatioRequest.ratio"));
        Object rawSplit = Wire.required(object, "split");
        builder.split(Wire.uint64(rawSplit, "SetSplitRatioRequest.split"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "SetSplitRatioRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ratio", ratio);
        Wire.put(object, "split", split);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetSplitRatioRequest that)) return false;
        return Objects.equals(ratio, that.ratio) && Objects.equals(split, that.split) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(ratio, split, transaction); }

    @Override
    public String toString() { return "SetSplitRatioRequest" + toWire(); }

    public static final class Builder {
        private Double ratio;
        private boolean ratioSet;
        private UInt64 split;
        private boolean splitSet;
        private Field<UInt64> transaction = Field.omitted();

        public Builder ratio(double value) {
            this.ratio = value;
            this.ratioSet = true;
            return this;
        }
        public Builder split(UInt64 value) {
            this.split = value;
            this.splitSet = true;
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public SetSplitRatioRequest build() { return new SetSplitRatioRequest(this); }
    }
}

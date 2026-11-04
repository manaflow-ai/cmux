// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-layout-sizes request. Protocol v12; authority: control. */
public final class SetLayoutSizesRequest implements WireValue {
    private final UInt64 transaction;
    private final List<LayoutSizeValue> values;

    private SetLayoutSizesRequest(Builder builder) {
        if (!builder.transactionSet) throw new IllegalArgumentException("transaction is required");
        this.transaction = Wire.nonNull(builder.transaction, "transaction");
        if (!builder.valuesSet) throw new IllegalArgumentException("values is required");
        this.values = List.copyOf(Wire.nonNull(builder.values, "values"));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 transaction() { return transaction; }
    public List<LayoutSizeValue> values() { return values; }

    public static SetLayoutSizesRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetLayoutSizesRequest");
        Builder builder = builder();
        Object rawTransaction = Wire.required(object, "transaction");
        builder.transaction(Wire.uint64(rawTransaction, "SetLayoutSizesRequest.transaction"));
        Object rawValues = Wire.required(object, "values");
        builder.values(Wire.array(rawValues, "SetLayoutSizesRequest.values", item -> LayoutSizeValue.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "values", values);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetLayoutSizesRequest that)) return false;
        return Objects.equals(transaction, that.transaction) && Objects.equals(values, that.values);
    }

    @Override
    public int hashCode() { return Objects.hash(transaction, values); }

    @Override
    public String toString() { return "SetLayoutSizesRequest" + toWire(); }

    public static final class Builder {
        private UInt64 transaction;
        private boolean transactionSet;
        private List<LayoutSizeValue> values;
        private boolean valuesSet;

        public Builder transaction(UInt64 value) {
            this.transaction = value;
            this.transactionSet = true;
            return this;
        }
        public Builder values(List<LayoutSizeValue> value) {
            this.values = value;
            this.valuesSet = true;
            return this;
        }
        public SetLayoutSizesRequest build() { return new SetLayoutSizesRequest(this); }
    }
}

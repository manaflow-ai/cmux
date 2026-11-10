// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-divider-visible request. Protocol v12; authority: control. */
public final class SetDividerVisibleRequest implements WireValue {
    private final UInt64 split;
    private final Field<UInt64> transaction;
    private final boolean visible;

    private SetDividerVisibleRequest(Builder builder) {
        if (!builder.splitSet) throw new IllegalArgumentException("split is required");
        this.split = Wire.nonNull(builder.split, "split");
        this.transaction = builder.transaction;
        if (!builder.visibleSet) throw new IllegalArgumentException("visible is required");
        this.visible = builder.visible;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 split() { return split; }
    public Field<UInt64> transaction() { return transaction; }
    public boolean visible() { return visible; }

    public static SetDividerVisibleRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetDividerVisibleRequest");
        Builder builder = builder();
        Object rawSplit = Wire.required(object, "split");
        builder.split(Wire.uint64(rawSplit, "SetDividerVisibleRequest.split"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "SetDividerVisibleRequest.transaction"));
        }
        Object rawVisible = Wire.required(object, "visible");
        builder.visible(Wire.bool(rawVisible, "SetDividerVisibleRequest.visible"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "split", split);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "visible", visible);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetDividerVisibleRequest that)) return false;
        return Objects.equals(split, that.split) && Objects.equals(transaction, that.transaction) && Objects.equals(visible, that.visible);
    }

    @Override
    public int hashCode() { return Objects.hash(split, transaction, visible); }

    @Override
    public String toString() { return "SetDividerVisibleRequest" + toWire(); }

    public static final class Builder {
        private UInt64 split;
        private boolean splitSet;
        private Field<UInt64> transaction = Field.omitted();
        private Boolean visible;
        private boolean visibleSet;

        public Builder split(UInt64 value) {
            this.split = value;
            this.splitSet = true;
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder visible(boolean value) {
            this.visible = value;
            this.visibleSet = true;
            return this;
        }
        public SetDividerVisibleRequest build() { return new SetDividerVisibleRequest(this); }
    }
}

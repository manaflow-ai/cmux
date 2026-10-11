// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-row-heights request. Protocol v12; authority: control. */
public final class SetRowHeightsRequest implements WireValue {
    private final UInt64 column;
    private final Field<Boolean> fit;
    private final List<RowHeight> heights;
    private final Field<UInt64> transaction;

    private SetRowHeightsRequest(Builder builder) {
        if (!builder.columnSet) throw new IllegalArgumentException("column is required");
        this.column = Wire.nonNull(builder.column, "column");
        this.fit = builder.fit;
        if (!builder.heightsSet) throw new IllegalArgumentException("heights is required");
        this.heights = List.copyOf(Wire.nonNull(builder.heights, "heights"));
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 column() { return column; }
    public Field<Boolean> fit() { return fit; }
    public List<RowHeight> heights() { return heights; }
    public Field<UInt64> transaction() { return transaction; }

    public static SetRowHeightsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetRowHeightsRequest");
        Builder builder = builder();
        Object rawColumn = Wire.required(object, "column");
        builder.column(Wire.uint64(rawColumn, "SetRowHeightsRequest.column"));
        Object rawFit = Wire.optional(object, "fit");
        if (!Wire.isMissing(rawFit)) {
            builder.fit(Wire.bool(rawFit, "SetRowHeightsRequest.fit"));
        }
        Object rawHeights = Wire.required(object, "heights");
        builder.heights(Wire.array(rawHeights, "SetRowHeightsRequest.heights", item -> RowHeight.fromWire(item)));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "SetRowHeightsRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "column", column);
        Wire.put(object, "fit", fit);
        Wire.put(object, "heights", heights);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetRowHeightsRequest that)) return false;
        return Objects.equals(column, that.column) && Objects.equals(fit, that.fit) && Objects.equals(heights, that.heights) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(column, fit, heights, transaction); }

    @Override
    public String toString() { return "SetRowHeightsRequest" + toWire(); }

    public static final class Builder {
        private UInt64 column;
        private boolean columnSet;
        private Field<Boolean> fit = Field.omitted();
        private List<RowHeight> heights;
        private boolean heightsSet;
        private Field<UInt64> transaction = Field.omitted();

        public Builder column(UInt64 value) {
            this.column = value;
            this.columnSet = true;
            return this;
        }
        public Builder fit(Boolean value) {
            this.fit = Field.of(value);
            return this;
        }
        public Builder heights(List<RowHeight> value) {
            this.heights = value;
            this.heightsSet = true;
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public SetRowHeightsRequest build() { return new SetRowHeightsRequest(this); }
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-viewport-pane-width request. Protocol v9; authority: control. */
public final class SetViewportPaneWidthRequest implements WireValue {
    private final UInt64 pane;
    private final Field<UInt64> transaction;
    private final double width;

    private SetViewportPaneWidthRequest(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.transaction = builder.transaction;
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public Field<UInt64> transaction() { return transaction; }
    public double width() { return width; }

    public static SetViewportPaneWidthRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetViewportPaneWidthRequest");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SetViewportPaneWidthRequest.pane"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "SetViewportPaneWidthRequest.transaction"));
        }
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "SetViewportPaneWidthRequest.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetViewportPaneWidthRequest that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(transaction, that.transaction) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, transaction, width); }

    @Override
    public String toString() { return "SetViewportPaneWidthRequest" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private Field<UInt64> transaction = Field.omitted();
        private Double width;
        private boolean widthSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public SetViewportPaneWidthRequest build() { return new SetViewportPaneWidthRequest(this); }
    }
}

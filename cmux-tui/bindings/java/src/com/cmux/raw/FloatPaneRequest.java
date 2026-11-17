// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable float-pane request. Protocol v12; authority: control. */
public final class FloatPaneRequest implements WireValue {
    private final Field<Double> h;
    private final Field<String> mode;
    private final UInt64 pane;
    private final Field<UInt64> transaction;
    private final Field<Double> w;
    private final Field<Double> x;
    private final Field<Double> y;

    private FloatPaneRequest(Builder builder) {
        this.h = builder.h;
        this.mode = builder.mode;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.transaction = builder.transaction;
        this.w = builder.w;
        this.x = builder.x;
        this.y = builder.y;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Double> h() { return h; }
    public Field<String> mode() { return mode; }
    public UInt64 pane() { return pane; }
    public Field<UInt64> transaction() { return transaction; }
    public Field<Double> w() { return w; }
    public Field<Double> x() { return x; }
    public Field<Double> y() { return y; }

    public static FloatPaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FloatPaneRequest");
        Builder builder = builder();
        Object rawH = Wire.optional(object, "h");
        if (!Wire.isMissing(rawH)) {
            builder.h(rawH == null ? null : Wire.float64(rawH, "FloatPaneRequest.h"));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : Wire.string(rawMode, "FloatPaneRequest.mode"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "FloatPaneRequest.pane"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "FloatPaneRequest.transaction"));
        }
        Object rawW = Wire.optional(object, "w");
        if (!Wire.isMissing(rawW)) {
            builder.w(rawW == null ? null : Wire.float64(rawW, "FloatPaneRequest.w"));
        }
        Object rawX = Wire.optional(object, "x");
        if (!Wire.isMissing(rawX)) {
            builder.x(rawX == null ? null : Wire.float64(rawX, "FloatPaneRequest.x"));
        }
        Object rawY = Wire.optional(object, "y");
        if (!Wire.isMissing(rawY)) {
            builder.y(rawY == null ? null : Wire.float64(rawY, "FloatPaneRequest.y"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "h", h);
        Wire.put(object, "mode", mode);
        Wire.put(object, "pane", pane);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "w", w);
        Wire.put(object, "x", x);
        Wire.put(object, "y", y);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FloatPaneRequest that)) return false;
        return Objects.equals(h, that.h) && Objects.equals(mode, that.mode) && Objects.equals(pane, that.pane) && Objects.equals(transaction, that.transaction) && Objects.equals(w, that.w) && Objects.equals(x, that.x) && Objects.equals(y, that.y);
    }

    @Override
    public int hashCode() { return Objects.hash(h, mode, pane, transaction, w, x, y); }

    @Override
    public String toString() { return "FloatPaneRequest" + toWire(); }

    public static final class Builder {
        private Field<Double> h = Field.omitted();
        private Field<String> mode = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<UInt64> transaction = Field.omitted();
        private Field<Double> w = Field.omitted();
        private Field<Double> x = Field.omitted();
        private Field<Double> y = Field.omitted();

        public Builder h(Double value) {
            this.h = Field.ofNullable(value);
            return this;
        }
        public Builder mode(String value) {
            this.mode = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder w(Double value) {
            this.w = Field.ofNullable(value);
            return this;
        }
        public Builder x(Double value) {
            this.x = Field.ofNullable(value);
            return this;
        }
        public Builder y(Double value) {
            this.y = Field.ofNullable(value);
            return this;
        }
        public FloatPaneRequest build() { return new FloatPaneRequest(this); }
    }
}

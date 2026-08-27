// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable select-screen request. Protocol v5; authority: control. */
public final class SelectScreenRequest implements WireValue {
    private final Field<Long> delta;
    private final Field<UInt64> index;

    private SelectScreenRequest(Builder builder) {
        this.delta = builder.delta;
        this.index = builder.index;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Long> delta() { return delta; }
    public Field<UInt64> index() { return index; }

    public static SelectScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SelectScreenRequest");
        Builder builder = builder();
        Object rawDelta = Wire.optional(object, "delta");
        if (!Wire.isMissing(rawDelta)) {
            builder.delta(rawDelta == null ? null : Wire.int64(rawDelta, "SelectScreenRequest.delta"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "SelectScreenRequest.index"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "delta", delta);
        Wire.put(object, "index", index);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SelectScreenRequest that)) return false;
        return Objects.equals(delta, that.delta) && Objects.equals(index, that.index);
    }

    @Override
    public int hashCode() { return Objects.hash(delta, index); }

    @Override
    public String toString() { return "SelectScreenRequest" + toWire(); }

    public static final class Builder {
        private Field<Long> delta = Field.omitted();
        private Field<UInt64> index = Field.omitted();

        public Builder delta(Long value) {
            this.delta = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public SelectScreenRequest build() { return new SelectScreenRequest(this); }
    }
}

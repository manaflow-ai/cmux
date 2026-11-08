// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable select-tab request. Protocol v5; authority: control. */
public final class SelectTabRequest implements WireValue {
    private final Field<Long> delta;
    private final Field<UInt64> index;
    private final Field<UInt64> pane;

    private SelectTabRequest(Builder builder) {
        this.delta = builder.delta;
        this.index = builder.index;
        this.pane = builder.pane;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Long> delta() { return delta; }
    public Field<UInt64> index() { return index; }
    public Field<UInt64> pane() { return pane; }

    public static SelectTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SelectTabRequest");
        Builder builder = builder();
        Object rawDelta = Wire.optional(object, "delta");
        if (!Wire.isMissing(rawDelta)) {
            builder.delta(rawDelta == null ? null : Wire.int64(rawDelta, "SelectTabRequest.delta"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "SelectTabRequest.index"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "SelectTabRequest.pane"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "delta", delta);
        Wire.put(object, "index", index);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SelectTabRequest that)) return false;
        return Objects.equals(delta, that.delta) && Objects.equals(index, that.index) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(delta, index, pane); }

    @Override
    public String toString() { return "SelectTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Long> delta = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private Field<UInt64> pane = Field.omitted();

        public Builder delta(Long value) {
            this.delta = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public SelectTabRequest build() { return new SelectTabRequest(this); }
    }
}

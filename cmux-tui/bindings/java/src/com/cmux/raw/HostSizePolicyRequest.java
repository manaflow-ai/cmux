// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HostSizePolicyRequest implements WireValue {
    private final HostSizeMode mode;
    private final Field<List<String>> order;

    private HostSizePolicyRequest(Builder builder) {
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        this.order = builder.order.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public HostSizeMode mode() { return mode; }
    public Field<List<String>> order() { return order; }

    public static HostSizePolicyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HostSizePolicyRequest");
        Builder builder = builder();
        Object rawMode = Wire.required(object, "mode");
        builder.mode(HostSizeMode.fromWire(rawMode));
        Object rawOrder = Wire.optional(object, "order");
        if (!Wire.isMissing(rawOrder)) {
            builder.order(rawOrder == null ? null : Wire.array(rawOrder, "HostSizePolicyRequest.order", item -> Wire.string(item, "HostSizePolicyRequest.order item")));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mode", mode);
        Wire.put(object, "order", order);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HostSizePolicyRequest that)) return false;
        return Objects.equals(mode, that.mode) && Objects.equals(order, that.order);
    }

    @Override
    public int hashCode() { return Objects.hash(mode, order); }

    @Override
    public String toString() { return "HostSizePolicyRequest" + toWire(); }

    public static final class Builder {
        private HostSizeMode mode;
        private boolean modeSet;
        private Field<List<String>> order = Field.omitted();

        public Builder mode(HostSizeMode value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder order(List<String> value) {
            this.order = Field.ofNullable(value);
            return this;
        }
        public HostSizePolicyRequest build() { return new HostSizePolicyRequest(this); }
    }
}

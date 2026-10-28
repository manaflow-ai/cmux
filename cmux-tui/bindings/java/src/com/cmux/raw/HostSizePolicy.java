// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HostSizePolicy implements WireValue {
    private final HostSizeMode mode;
    private final List<String> order;

    private HostSizePolicy(Builder builder) {
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        if (!builder.orderSet) throw new IllegalArgumentException("order is required");
        this.order = List.copyOf(Wire.nonNull(builder.order, "order"));
    }

    public static Builder builder() { return new Builder(); }

    public HostSizeMode mode() { return mode; }
    public List<String> order() { return order; }

    public static HostSizePolicy fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HostSizePolicy");
        Builder builder = builder();
        Object rawMode = Wire.required(object, "mode");
        builder.mode(HostSizeMode.fromWire(rawMode));
        Object rawOrder = Wire.required(object, "order");
        builder.order(Wire.array(rawOrder, "HostSizePolicy.order", item -> Wire.string(item, "HostSizePolicy.order item")));
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
        if (!(other instanceof HostSizePolicy that)) return false;
        return Objects.equals(mode, that.mode) && Objects.equals(order, that.order);
    }

    @Override
    public int hashCode() { return Objects.hash(mode, order); }

    @Override
    public String toString() { return "HostSizePolicy" + toWire(); }

    public static final class Builder {
        private HostSizeMode mode;
        private boolean modeSet;
        private List<String> order;
        private boolean orderSet;

        public Builder mode(HostSizeMode value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder order(List<String> value) {
            this.order = value;
            this.orderSet = true;
            return this;
        }
        public HostSizePolicy build() { return new HostSizePolicy(this); }
    }
}

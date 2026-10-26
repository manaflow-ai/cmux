// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsRunResult implements WireValue {
    private final Object value;

    private AppsRunResult(Builder builder) {
        if (!builder.valueSet) throw new IllegalArgumentException("value is required");
        this.value = builder.value == null ? null : Wire.immutableJson(builder.value);
    }

    public static Builder builder() { return new Builder(); }

    public Object value() { return value; }

    public static AppsRunResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsRunResult");
        Builder builder = builder();
        Object rawValue = Wire.required(object, "value");
        builder.value(rawValue == null ? null : Wire.immutableJson(rawValue));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "value", value);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsRunResult that)) return false;
        return Objects.equals(value, that.value);
    }

    @Override
    public int hashCode() { return Objects.hash(value); }

    @Override
    public String toString() { return "AppsRunResult" + toWire(); }

    public static final class Builder {
        private Object value;
        private boolean valueSet;

        public Builder value(Object value) {
            this.value = value;
            this.valueSet = true;
            return this;
        }
        public AppsRunResult build() { return new AppsRunResult(this); }
    }
}

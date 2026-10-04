// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cancel-request request. Protocol v12; authority: control. */
public final class CancelRequestRequest implements WireValue {
    private final Object target;

    private CancelRequestRequest(Builder builder) {
        if (!builder.targetSet) throw new IllegalArgumentException("target is required");
        this.target = builder.target == null ? null : Wire.immutableJson(builder.target);
    }

    public static Builder builder() { return new Builder(); }

    public Object target() { return target; }

    public static CancelRequestRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CancelRequestRequest");
        Builder builder = builder();
        Object rawTarget = Wire.required(object, "target");
        builder.target(rawTarget == null ? null : Wire.immutableJson(rawTarget));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "target", target);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CancelRequestRequest that)) return false;
        return Objects.equals(target, that.target);
    }

    @Override
    public int hashCode() { return Objects.hash(target); }

    @Override
    public String toString() { return "CancelRequestRequest" + toWire(); }

    public static final class Builder {
        private Object target;
        private boolean targetSet;

        public Builder target(Object value) {
            this.target = value;
            this.targetSet = true;
            return this;
        }
        public CancelRequestRequest build() { return new CancelRequestRequest(this); }
    }
}

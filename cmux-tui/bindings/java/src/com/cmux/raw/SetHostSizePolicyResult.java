// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetHostSizePolicyResult implements WireValue {
    private final HostSizePolicy policy;

    private SetHostSizePolicyResult(Builder builder) {
        if (!builder.policySet) throw new IllegalArgumentException("policy is required");
        this.policy = Wire.nonNull(builder.policy, "policy");
    }

    public static Builder builder() { return new Builder(); }

    public HostSizePolicy policy() { return policy; }

    public static SetHostSizePolicyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetHostSizePolicyResult");
        Builder builder = builder();
        Object rawPolicy = Wire.required(object, "policy");
        builder.policy(HostSizePolicy.fromWire(rawPolicy));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "policy", policy);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetHostSizePolicyResult that)) return false;
        return Objects.equals(policy, that.policy);
    }

    @Override
    public int hashCode() { return Objects.hash(policy); }

    @Override
    public String toString() { return "SetHostSizePolicyResult" + toWire(); }

    public static final class Builder {
        private HostSizePolicy policy;
        private boolean policySet;

        public Builder policy(HostSizePolicy value) {
            this.policy = value;
            this.policySet = true;
            return this;
        }
        public SetHostSizePolicyResult build() { return new SetHostSizePolicyResult(this); }
    }
}

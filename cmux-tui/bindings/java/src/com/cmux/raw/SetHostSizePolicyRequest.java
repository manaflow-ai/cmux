// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-host-size-policy request. Protocol v12; authority: control. */
public final class SetHostSizePolicyRequest implements WireValue {
    private final HostSizePolicyRequest policy;

    private SetHostSizePolicyRequest(Builder builder) {
        if (!builder.policySet) throw new IllegalArgumentException("policy is required");
        this.policy = Wire.nonNull(builder.policy, "policy");
    }

    public static Builder builder() { return new Builder(); }

    public HostSizePolicyRequest policy() { return policy; }

    public static SetHostSizePolicyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetHostSizePolicyRequest");
        Builder builder = builder();
        Object rawPolicy = Wire.required(object, "policy");
        builder.policy(HostSizePolicyRequest.fromWire(rawPolicy));
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
        if (!(other instanceof SetHostSizePolicyRequest that)) return false;
        return Objects.equals(policy, that.policy);
    }

    @Override
    public int hashCode() { return Objects.hash(policy); }

    @Override
    public String toString() { return "SetHostSizePolicyRequest" + toWire(); }

    public static final class Builder {
        private HostSizePolicyRequest policy;
        private boolean policySet;

        public Builder policy(HostSizePolicyRequest value) {
            this.policy = value;
            this.policySet = true;
            return this;
        }
        public SetHostSizePolicyRequest build() { return new SetHostSizePolicyRequest(this); }
    }
}

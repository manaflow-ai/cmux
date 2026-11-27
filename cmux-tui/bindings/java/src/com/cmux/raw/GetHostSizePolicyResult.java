// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GetHostSizePolicyResult implements WireValue {
    private final List<String> macParticipants;
    private final HostSizePolicy policy;

    private GetHostSizePolicyResult(Builder builder) {
        if (!builder.macParticipantsSet) throw new IllegalArgumentException("mac_participants is required");
        this.macParticipants = List.copyOf(Wire.nonNull(builder.macParticipants, "mac_participants"));
        if (!builder.policySet) throw new IllegalArgumentException("policy is required");
        this.policy = Wire.nonNull(builder.policy, "policy");
    }

    public static Builder builder() { return new Builder(); }

    public List<String> macParticipants() { return macParticipants; }
    public HostSizePolicy policy() { return policy; }

    public static GetHostSizePolicyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetHostSizePolicyResult");
        Builder builder = builder();
        Object rawMacParticipants = Wire.required(object, "mac_participants");
        builder.macParticipants(Wire.array(rawMacParticipants, "GetHostSizePolicyResult.mac_participants", item -> Wire.string(item, "GetHostSizePolicyResult.mac_participants item")));
        Object rawPolicy = Wire.required(object, "policy");
        builder.policy(HostSizePolicy.fromWire(rawPolicy));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mac_participants", macParticipants);
        Wire.put(object, "policy", policy);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetHostSizePolicyResult that)) return false;
        return Objects.equals(macParticipants, that.macParticipants) && Objects.equals(policy, that.policy);
    }

    @Override
    public int hashCode() { return Objects.hash(macParticipants, policy); }

    @Override
    public String toString() { return "GetHostSizePolicyResult" + toWire(); }

    public static final class Builder {
        private List<String> macParticipants;
        private boolean macParticipantsSet;
        private HostSizePolicy policy;
        private boolean policySet;

        public Builder macParticipants(List<String> value) {
            this.macParticipants = value;
            this.macParticipantsSet = true;
            return this;
        }
        public Builder policy(HostSizePolicy value) {
            this.policy = value;
            this.policySet = true;
            return this;
        }
        public GetHostSizePolicyResult build() { return new GetHostSizePolicyResult(this); }
    }
}

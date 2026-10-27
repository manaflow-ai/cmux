// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobResolutionPending implements WireValue, AgentClijobResolution {

    private AgentClijobResolutionPending(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public String state() { return "pending"; }

    public static AgentClijobResolutionPending fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolutionPending");
        Builder builder = builder();
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "pending", "AgentClijobResolutionPending.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", "pending");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobResolutionPending that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "AgentClijobResolutionPending" + toWire(); }

    public static final class Builder {

        public AgentClijobResolutionPending build() { return new AgentClijobResolutionPending(this); }
    }
}

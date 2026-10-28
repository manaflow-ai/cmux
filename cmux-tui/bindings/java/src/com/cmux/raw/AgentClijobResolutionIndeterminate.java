// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobResolutionIndeterminate implements WireValue, AgentClijobResolution {

    private AgentClijobResolutionIndeterminate(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public String state() { return "indeterminate"; }

    public static AgentClijobResolutionIndeterminate fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolutionIndeterminate");
        Builder builder = builder();
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "indeterminate", "AgentClijobResolutionIndeterminate.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", "indeterminate");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobResolutionIndeterminate that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "AgentClijobResolutionIndeterminate" + toWire(); }

    public static final class Builder {

        public AgentClijobResolutionIndeterminate build() { return new AgentClijobResolutionIndeterminate(this); }
    }
}

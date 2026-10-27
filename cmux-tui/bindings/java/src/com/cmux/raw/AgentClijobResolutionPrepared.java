// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobResolutionPrepared implements WireValue, AgentClijobResolution {

    private AgentClijobResolutionPrepared(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public String state() { return "prepared"; }

    public static AgentClijobResolutionPrepared fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolutionPrepared");
        Builder builder = builder();
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "prepared", "AgentClijobResolutionPrepared.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", "prepared");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobResolutionPrepared that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "AgentClijobResolutionPrepared" + toWire(); }

    public static final class Builder {

        public AgentClijobResolutionPrepared build() { return new AgentClijobResolutionPrepared(this); }
    }
}

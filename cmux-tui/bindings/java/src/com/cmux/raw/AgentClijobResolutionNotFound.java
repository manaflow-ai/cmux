// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobResolutionNotFound implements WireValue, AgentClijobResolution {

    private AgentClijobResolutionNotFound(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public String state() { return "not_found"; }

    public static AgentClijobResolutionNotFound fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolutionNotFound");
        Builder builder = builder();
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "not_found", "AgentClijobResolutionNotFound.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", "not_found");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobResolutionNotFound that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "AgentClijobResolutionNotFound" + toWire(); }

    public static final class Builder {

        public AgentClijobResolutionNotFound build() { return new AgentClijobResolutionNotFound(this); }
    }
}

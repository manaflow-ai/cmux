// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AgentState implements WireEnum {
    WORKING("working"),
    BLOCKED("blocked"),
    IDLE("idle"),
    DONE("done"),
    UNKNOWN("unknown");

    private final Object wireValue;

    AgentState(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AgentState fromWire(Object value) {
        for (AgentState candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AgentState value " + value, null);
    }
}

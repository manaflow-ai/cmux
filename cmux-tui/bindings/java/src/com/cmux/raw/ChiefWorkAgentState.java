// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ChiefWorkAgentState implements WireEnum {
    WORKING("working"),
    WAITING("waiting"),
    IDLE("idle"),
    FAILED("failed");

    private final Object wireValue;

    ChiefWorkAgentState(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ChiefWorkAgentState fromWire(Object value) {
        for (ChiefWorkAgentState candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ChiefWorkAgentState value " + value, null);
    }
}

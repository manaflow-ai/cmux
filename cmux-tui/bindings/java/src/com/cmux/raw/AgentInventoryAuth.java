// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AgentInventoryAuth implements WireEnum {
    SIGNED_IN("signedIn"),
    SIGNED_OUT("signedOut"),
    UNKNOWN("unknown");

    private final Object wireValue;

    AgentInventoryAuth(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AgentInventoryAuth fromWire(Object value) {
        for (AgentInventoryAuth candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AgentInventoryAuth value " + value, null);
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AgentInventoryChannel implements WireEnum {
    NPM("npm"),
    BUN("bun"),
    BREW("brew"),
    BREW_CASK("brewCask"),
    NATIVE("native"),
    LAUNCHER("launcher"),
    STANDALONE("standalone"),
    MISSING("missing");

    private final Object wireValue;

    AgentInventoryChannel(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AgentInventoryChannel fromWire(Object value) {
        for (AgentInventoryChannel candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AgentInventoryChannel value " + value, null);
    }
}

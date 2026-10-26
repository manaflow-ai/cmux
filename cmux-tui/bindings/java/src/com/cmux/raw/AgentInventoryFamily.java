// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AgentInventoryFamily implements WireEnum {
    CLAUDE("claude"),
    CODEX("codex"),
    OPENCODE("opencode"),
    PI("pi"),
    CHIEF("chief"),
    GEMINI("gemini"),
    AMP("amp"),
    COPILOT("copilot"),
    CURSOR("cursor");

    private final Object wireValue;

    AgentInventoryFamily(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AgentInventoryFamily fromWire(Object value) {
        for (AgentInventoryFamily candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AgentInventoryFamily value " + value, null);
    }
}

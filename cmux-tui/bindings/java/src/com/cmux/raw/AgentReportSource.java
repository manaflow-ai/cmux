// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AgentReportSource implements WireEnum {
    SOCKET("socket"),
    HOOK("hook");

    private final Object wireValue;

    AgentReportSource(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AgentReportSource fromWire(Object value) {
        for (AgentReportSource candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AgentReportSource value " + value, null);
    }
}

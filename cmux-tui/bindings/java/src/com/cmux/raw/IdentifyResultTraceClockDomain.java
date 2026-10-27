// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum IdentifyResultTraceClockDomain implements WireEnum {
    UPTIME_RAW("uptime_raw"),
    MONOTONIC("monotonic"),
    QPC("qpc");

    private final Object wireValue;

    IdentifyResultTraceClockDomain(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static IdentifyResultTraceClockDomain fromWire(Object value) {
        for (IdentifyResultTraceClockDomain candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown IdentifyResultTraceClockDomain value " + value, null);
    }
}

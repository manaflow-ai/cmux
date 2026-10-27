// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum CancelStreamResultOutcome implements WireEnum {
    APPLIED("applied"),
    ENDED("ended");

    private final Object wireValue;

    CancelStreamResultOutcome(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static CancelStreamResultOutcome fromWire(Object value) {
        for (CancelStreamResultOutcome candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown CancelStreamResultOutcome value " + value, null);
    }
}

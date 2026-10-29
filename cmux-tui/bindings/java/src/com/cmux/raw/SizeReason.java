// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum SizeReason implements WireEnum {
    LATEST("latest"),
    SMALLEST("smallest"),
    LARGEST("largest"),
    PRIORITY("priority"),
    FIXED("fixed"),
    HELD("held"),
    PRIORITY_FALLBACK("priority-fallback");

    private final Object wireValue;

    SizeReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SizeReason fromWire(Object value) {
        for (SizeReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown SizeReason value " + value, null);
    }
}

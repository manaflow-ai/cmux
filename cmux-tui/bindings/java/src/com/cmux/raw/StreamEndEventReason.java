// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum StreamEndEventReason implements WireEnum {
    CANCELED("canceled"),
    DETACHED("detached"),
    OVERFLOW("overflow"),
    ATTACH_FAILED("attach_failed");

    private final Object wireValue;

    StreamEndEventReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static StreamEndEventReason fromWire(Object value) {
        for (StreamEndEventReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown StreamEndEventReason value " + value, null);
    }
}

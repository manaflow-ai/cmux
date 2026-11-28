// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum DetachReason implements WireEnum {
    NETWORK("network"),
    DISCONNECTED_BY("disconnected-by"),
    HOST_SHUTDOWN("host-shutdown"),
    SUPERSEDED("superseded");

    private final Object wireValue;

    DetachReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static DetachReason fromWire(Object value) {
        for (DetachReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown DetachReason value " + value, null);
    }
}

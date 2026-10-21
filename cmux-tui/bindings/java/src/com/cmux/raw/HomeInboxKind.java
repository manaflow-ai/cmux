// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum HomeInboxKind implements WireEnum {
    CHIEF("chief"),
    DIRECT("direct"),
    CHANNEL("channel"),
    GROUP("group");

    private final Object wireValue;

    HomeInboxKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static HomeInboxKind fromWire(Object value) {
        for (HomeInboxKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown HomeInboxKind value " + value, null);
    }
}

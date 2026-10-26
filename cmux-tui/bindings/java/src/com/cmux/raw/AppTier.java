// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AppTier implements WireEnum {
    FIRST_PARTY("first-party"),
    VERIFIED("verified"),
    UNVERIFIED("unverified");

    private final Object wireValue;

    AppTier(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AppTier fromWire(Object value) {
        for (AppTier candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AppTier value " + value, null);
    }
}

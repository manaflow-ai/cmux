// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum BrowserProviderAuthentication implements WireEnum {
    NONE("none"),
    BEARER("bearer");

    private final Object wireValue;

    BrowserProviderAuthentication(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static BrowserProviderAuthentication fromWire(Object value) {
        for (BrowserProviderAuthentication candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown BrowserProviderAuthentication value " + value, null);
    }
}

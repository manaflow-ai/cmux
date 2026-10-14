// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum BrowserProviderHosting implements WireEnum {
    DAEMON("daemon"),
    NATIVE("native");

    private final Object wireValue;

    BrowserProviderHosting(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static BrowserProviderHosting fromWire(Object value) {
        for (BrowserProviderHosting candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown BrowserProviderHosting value " + value, null);
    }
}

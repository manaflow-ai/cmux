// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TabBrowserSource implements WireEnum {
    EXTERNAL("external"),
    LAUNCHED("launched");

    private final Object wireValue;

    TabBrowserSource(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TabBrowserSource fromWire(Object value) {
        for (TabBrowserSource candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TabBrowserSource value " + value, null);
    }
}

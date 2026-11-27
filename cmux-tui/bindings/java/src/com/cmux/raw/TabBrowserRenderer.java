// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TabBrowserRenderer implements WireEnum {
    DAEMON("daemon"),
    FRONTEND("frontend");

    private final Object wireValue;

    TabBrowserRenderer(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TabBrowserRenderer fromWire(Object value) {
        for (TabBrowserRenderer candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TabBrowserRenderer value " + value, null);
    }
}

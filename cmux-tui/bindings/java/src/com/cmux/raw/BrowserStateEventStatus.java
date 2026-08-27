// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum BrowserStateEventStatus implements WireEnum {
    STARTING("starting"),
    LIVE("live"),
    FAILED("failed");

    private final Object wireValue;

    BrowserStateEventStatus(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static BrowserStateEventStatus fromWire(Object value) {
        for (BrowserStateEventStatus candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown BrowserStateEventStatus value " + value, null);
    }
}

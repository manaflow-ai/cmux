// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum BrowserKeyRequestKind implements WireEnum {
    DOWN("down"),
    UP("up");

    private final Object wireValue;

    BrowserKeyRequestKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static BrowserKeyRequestKind fromWire(Object value) {
        for (BrowserKeyRequestKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown BrowserKeyRequestKind value " + value, null);
    }
}

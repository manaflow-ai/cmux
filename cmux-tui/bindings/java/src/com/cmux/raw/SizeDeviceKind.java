// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum SizeDeviceKind implements WireEnum {
    MAC("mac"),
    IPHONE("iphone"),
    IPAD("ipad"),
    TUI("tui"),
    BROWSER("browser"),
    UNKNOWN("unknown");

    private final Object wireValue;

    SizeDeviceKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SizeDeviceKind fromWire(Object value) {
        for (SizeDeviceKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown SizeDeviceKind value " + value, null);
    }
}

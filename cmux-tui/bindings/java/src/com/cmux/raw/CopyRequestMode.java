// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum CopyRequestMode implements WireEnum {
    SCREEN("screen"),
    SELECTION("selection"),
    SCROLLBACK("scrollback");

    private final Object wireValue;

    CopyRequestMode(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static CopyRequestMode fromWire(Object value) {
        for (CopyRequestMode candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown CopyRequestMode value " + value, null);
    }
}

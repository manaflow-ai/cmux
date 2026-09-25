// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ZoomPaneRequestMode implements WireEnum {
    TOGGLE("toggle"),
    ON("on"),
    OFF("off");

    private final Object wireValue;

    ZoomPaneRequestMode(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ZoomPaneRequestMode fromWire(Object value) {
        for (ZoomPaneRequestMode candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ZoomPaneRequestMode value " + value, null);
    }
}

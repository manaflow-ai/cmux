// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum PresenceHighlightMode implements WireEnum {
    LASER("laser"),
    PIN("pin");

    private final Object wireValue;

    PresenceHighlightMode(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static PresenceHighlightMode fromWire(Object value) {
        for (PresenceHighlightMode candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown PresenceHighlightMode value " + value, null);
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ChiefChangedEventChange implements WireEnum {
    CREATED("created"),
    UPDATED("updated"),
    DELETED("deleted");

    private final Object wireValue;

    ChiefChangedEventChange(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ChiefChangedEventChange fromWire(Object value) {
        for (ChiefChangedEventChange candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ChiefChangedEventChange value " + value, null);
    }
}

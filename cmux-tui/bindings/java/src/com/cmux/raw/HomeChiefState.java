// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum HomeChiefState implements WireEnum {
    WORKING("working"),
    WAITING("waiting"),
    IDLE("idle");

    private final Object wireValue;

    HomeChiefState(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static HomeChiefState fromWire(Object value) {
        for (HomeChiefState candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown HomeChiefState value " + value, null);
    }
}

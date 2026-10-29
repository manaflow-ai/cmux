// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum EnergySaverReason implements WireEnum {
    LOW_POWER_MODE("lowPowerMode"),
    BATTERY("battery"),
    THERMAL("thermal"),
    SETTING("setting");

    private final Object wireValue;

    EnergySaverReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static EnergySaverReason fromWire(Object value) {
        for (EnergySaverReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown EnergySaverReason value " + value, null);
    }
}

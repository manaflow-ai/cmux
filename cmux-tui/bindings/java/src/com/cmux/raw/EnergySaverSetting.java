// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum EnergySaverSetting implements WireEnum {
    AUTO("auto"),
    ON_BATTERY("onBattery"),
    ALWAYS("always"),
    OFF("off");

    private final Object wireValue;

    EnergySaverSetting(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static EnergySaverSetting fromWire(Object value) {
        for (EnergySaverSetting candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown EnergySaverSetting value " + value, null);
    }
}

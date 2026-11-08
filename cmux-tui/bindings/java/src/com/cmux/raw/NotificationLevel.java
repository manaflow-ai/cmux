// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum NotificationLevel implements WireEnum {
    INFO("info"),
    WARNING("warning"),
    ERROR("error");

    private final Object wireValue;

    NotificationLevel(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static NotificationLevel fromWire(Object value) {
        for (NotificationLevel candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown NotificationLevel value " + value, null);
    }
}

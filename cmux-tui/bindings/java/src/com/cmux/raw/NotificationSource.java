// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum NotificationSource implements WireEnum {
    CLI("cli"),
    TERMINAL("terminal"),
    AGENT("agent"),
    DAEMON("daemon");

    private final Object wireValue;

    NotificationSource(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static NotificationSource fromWire(Object value) {
        for (NotificationSource candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown NotificationSource value " + value, null);
    }
}

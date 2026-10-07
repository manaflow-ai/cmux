// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum NotificationProgramStatusState implements WireEnum {
    BLOCKED("blocked"),
    ERROR("error");

    private final Object wireValue;

    NotificationProgramStatusState(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static NotificationProgramStatusState fromWire(Object value) {
        for (NotificationProgramStatusState candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown NotificationProgramStatusState value " + value, null);
    }
}

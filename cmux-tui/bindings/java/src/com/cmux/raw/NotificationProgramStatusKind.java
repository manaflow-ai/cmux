// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum NotificationProgramStatusKind implements WireEnum {
    PERMISSION("permission"),
    QUESTION("question"),
    AUTH("auth");

    private final Object wireValue;

    NotificationProgramStatusKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static NotificationProgramStatusKind fromWire(Object value) {
        for (NotificationProgramStatusKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown NotificationProgramStatusKind value " + value, null);
    }
}

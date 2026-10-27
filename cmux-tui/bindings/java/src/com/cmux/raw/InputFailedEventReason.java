// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum InputFailedEventReason implements WireEnum {
    TERMINAL_ENDED("terminal_ended"),
    NOT_A_TERMINAL("not_a_terminal"),
    WRITE_FAILED("write_failed"),
    DAEMON_HANDOFF("daemon_handoff"),
    OVERFLOW("overflow"),
    ATTACH_FAILED("attach_failed");

    private final Object wireValue;

    InputFailedEventReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static InputFailedEventReason fromWire(Object value) {
        for (InputFailedEventReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown InputFailedEventReason value " + value, null);
    }
}

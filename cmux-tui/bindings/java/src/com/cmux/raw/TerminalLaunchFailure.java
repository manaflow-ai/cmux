// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalLaunchFailure implements WireEnum {
    PTY_CAPACITY_EXHAUSTED("pty_capacity_exhausted");

    private final Object wireValue;

    TerminalLaunchFailure(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalLaunchFailure fromWire(Object value) {
        for (TerminalLaunchFailure candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalLaunchFailure value " + value, null);
    }
}

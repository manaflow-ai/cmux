// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalKeyAction implements WireEnum {
    PRESS("press"),
    RELEASE("release"),
    REPEAT("repeat");

    private final Object wireValue;

    TerminalKeyAction(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalKeyAction fromWire(Object value) {
        for (TerminalKeyAction candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalKeyAction value " + value, null);
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalLifecycleEventTo implements WireEnum {
    RUNNING("running"),
    EXITED("exited");

    private final Object wireValue;

    TerminalLifecycleEventTo(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalLifecycleEventTo fromWire(Object value) {
        for (TerminalLifecycleEventTo candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalLifecycleEventTo value " + value, null);
    }
}

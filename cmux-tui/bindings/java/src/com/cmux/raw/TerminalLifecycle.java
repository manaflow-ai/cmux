// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalLifecycle implements WireEnum {
    LAUNCHING("launching"),
    ADOPTING("adopting"),
    RUNNING("running"),
    EXITED("exited"),
    TOMBSTONED("tombstoned");

    private final Object wireValue;

    TerminalLifecycle(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalLifecycle fromWire(Object value) {
        for (TerminalLifecycle candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalLifecycle value " + value, null);
    }
}

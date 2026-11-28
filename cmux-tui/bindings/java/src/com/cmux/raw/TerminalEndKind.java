// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalEndKind implements WireEnum {
    EXITED("exited"),
    SIGNALED("signaled"),
    HOST_LOST("host_lost"),
    LAUNCH_FAILED("launch_failed");

    private final Object wireValue;

    TerminalEndKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalEndKind fromWire(Object value) {
        for (TerminalEndKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalEndKind value " + value, null);
    }
}

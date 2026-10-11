// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalClipboardHostKind implements WireEnum {
    LOCAL("local"),
    REMOTE("remote"),
    CLOUD("cloud");

    private final Object wireValue;

    TerminalClipboardHostKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalClipboardHostKind fromWire(Object value) {
        for (TerminalClipboardHostKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalClipboardHostKind value " + value, null);
    }
}

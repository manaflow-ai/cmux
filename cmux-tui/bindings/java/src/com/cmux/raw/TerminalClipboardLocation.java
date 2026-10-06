// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalClipboardLocation implements WireEnum {
    STANDARD("standard"),
    SELECTION("selection"),
    PRIMARY("primary");

    private final Object wireValue;

    TerminalClipboardLocation(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalClipboardLocation fromWire(Object value) {
        for (TerminalClipboardLocation candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalClipboardLocation value " + value, null);
    }
}

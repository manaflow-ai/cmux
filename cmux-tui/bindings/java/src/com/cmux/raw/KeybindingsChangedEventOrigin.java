// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum KeybindingsChangedEventOrigin implements WireEnum {
    USER("user"),
    CLI("cli"),
    MCP("mcp"),
    SCRIPT("script"),
    REMOTE("remote"),
    APP("app"),
    FILE("file");

    private final Object wireValue;

    KeybindingsChangedEventOrigin(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static KeybindingsChangedEventOrigin fromWire(Object value) {
        for (KeybindingsChangedEventOrigin candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown KeybindingsChangedEventOrigin value " + value, null);
    }
}

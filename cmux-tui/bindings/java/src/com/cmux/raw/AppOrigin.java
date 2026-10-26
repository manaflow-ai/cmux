// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AppOrigin implements WireEnum {
    USER("user"),
    CLI("cli"),
    MCP("mcp"),
    SCRIPT("script"),
    REMOTE("remote");

    private final Object wireValue;

    AppOrigin(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AppOrigin fromWire(Object value) {
        for (AppOrigin candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AppOrigin value " + value, null);
    }
}

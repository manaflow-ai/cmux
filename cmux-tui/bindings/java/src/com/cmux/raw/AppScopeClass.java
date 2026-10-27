// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AppScopeClass implements WireEnum {
    STANDARD("standard"),
    SENSITIVE("sensitive"),
    RESTRICTED("restricted"),
    ELEVATED("elevated"),
    UNKNOWN("unknown");

    private final Object wireValue;

    AppScopeClass(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AppScopeClass fromWire(Object value) {
        for (AppScopeClass candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AppScopeClass value " + value, null);
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AppSource implements WireEnum {
    DEFAULT("default"),
    USER("user"),
    BUNDLED("bundled"),
    LOCAL("local");

    private final Object wireValue;

    AppSource(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AppSource fromWire(Object value) {
        for (AppSource candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AppSource value " + value, null);
    }
}

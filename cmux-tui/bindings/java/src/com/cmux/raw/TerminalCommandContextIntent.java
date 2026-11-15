// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalCommandContextIntent implements WireEnum {
    CONTEXT("context"),
    FIX("fix");

    private final Object wireValue;

    TerminalCommandContextIntent(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalCommandContextIntent fromWire(Object value) {
        for (TerminalCommandContextIntent candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalCommandContextIntent value " + value, null);
    }
}

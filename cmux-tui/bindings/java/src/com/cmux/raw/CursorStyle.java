// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum CursorStyle implements WireEnum {
    BLOCK("block"),
    UNDERLINE("underline"),
    BAR("bar");

    private final Object wireValue;

    CursorStyle(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static CursorStyle fromWire(Object value) {
        for (CursorStyle candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown CursorStyle value " + value, null);
    }
}

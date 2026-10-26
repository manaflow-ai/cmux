// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum FsSortKey implements WireEnum {
    NAME("name"),
    MODIFIED("modified"),
    SIZE("size"),
    KIND("kind");

    private final Object wireValue;

    FsSortKey(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static FsSortKey fromWire(Object value) {
        for (FsSortKey candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown FsSortKey value " + value, null);
    }
}

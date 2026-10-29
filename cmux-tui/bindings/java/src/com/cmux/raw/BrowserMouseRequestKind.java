// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum BrowserMouseRequestKind implements WireEnum {
    DOWN("down"),
    UP("up"),
    MOVE("move");

    private final Object wireValue;

    BrowserMouseRequestKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static BrowserMouseRequestKind fromWire(Object value) {
        for (BrowserMouseRequestKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown BrowserMouseRequestKind value " + value, null);
    }
}

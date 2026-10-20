// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum IdsRequestKind implements WireEnum {
    WORKSPACE("workspace"),
    SCREEN("screen"),
    PANE("pane"),
    SURFACE("surface");

    private final Object wireValue;

    IdsRequestKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static IdsRequestKind fromWire(Object value) {
        for (IdsRequestKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown IdsRequestKind value " + value, null);
    }
}

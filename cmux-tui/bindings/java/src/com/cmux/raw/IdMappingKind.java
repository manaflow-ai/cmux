// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum IdMappingKind implements WireEnum {
    WORKSPACE("workspace"),
    SCREEN("screen"),
    PANE("pane"),
    SURFACE("surface");

    private final Object wireValue;

    IdMappingKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static IdMappingKind fromWire(Object value) {
        for (IdMappingKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown IdMappingKind value " + value, null);
    }
}

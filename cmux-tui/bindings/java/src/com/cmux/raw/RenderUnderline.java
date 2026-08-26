// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum RenderUnderline implements WireEnum {
    SINGLE("single"),
    DOUBLE("double"),
    CURLY("curly"),
    DOTTED("dotted"),
    DASHED("dashed");

    private final Object wireValue;

    RenderUnderline(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static RenderUnderline fromWire(Object value) {
        for (RenderUnderline candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown RenderUnderline value " + value, null);
    }
}

// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AttachSurfaceRequestMode implements WireEnum {
    BYTES("bytes"),
    RENDER("render");

    private final Object wireValue;

    AttachSurfaceRequestMode(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AttachSurfaceRequestMode fromWire(Object value) {
        for (AttachSurfaceRequestMode candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AttachSurfaceRequestMode value " + value, null);
    }
}

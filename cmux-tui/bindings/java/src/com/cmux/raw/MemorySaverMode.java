// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum MemorySaverMode implements WireEnum {
    OFF("off"),
    CONSERVATIVE("conservative"),
    MEDIUM("medium"),
    AGGRESSIVE("aggressive");

    private final Object wireValue;

    MemorySaverMode(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static MemorySaverMode fromWire(Object value) {
        for (MemorySaverMode candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown MemorySaverMode value " + value, null);
    }
}

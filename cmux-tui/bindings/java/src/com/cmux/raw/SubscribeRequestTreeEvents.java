// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum SubscribeRequestTreeEvents implements WireEnum {
    COARSE("coarse"),
    DELTAS("deltas");

    private final Object wireValue;

    SubscribeRequestTreeEvents(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SubscribeRequestTreeEvents fromWire(Object value) {
        for (SubscribeRequestTreeEvents candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown SubscribeRequestTreeEvents value " + value, null);
    }
}

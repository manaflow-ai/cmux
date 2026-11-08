// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ClientAttachedEventTransport implements WireEnum {
    UNIX("unix"),
    WS("ws");

    private final Object wireValue;

    ClientAttachedEventTransport(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ClientAttachedEventTransport fromWire(Object value) {
        for (ClientAttachedEventTransport candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ClientAttachedEventTransport value " + value, null);
    }
}

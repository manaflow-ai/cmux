// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ClientTransport implements WireEnum {
    LOCAL("local"),
    UNIX("unix"),
    WS("ws");

    private final Object wireValue;

    ClientTransport(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ClientTransport fromWire(Object value) {
        for (ClientTransport candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ClientTransport value " + value, null);
    }
}

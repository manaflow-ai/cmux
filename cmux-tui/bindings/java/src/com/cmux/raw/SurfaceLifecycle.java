// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum SurfaceLifecycle implements WireEnum {
    LAUNCHING("launching"),
    RUNNING("running");

    private final Object wireValue;

    SurfaceLifecycle(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SurfaceLifecycle fromWire(Object value) {
        for (SurfaceLifecycle candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown SurfaceLifecycle value " + value, null);
    }
}

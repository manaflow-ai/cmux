// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AppsCloudMachineEventKind implements WireEnum {
    RECORD("record"),
    LIVE("live"),
    LOST("lost");

    private final Object wireValue;

    AppsCloudMachineEventKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AppsCloudMachineEventKind fromWire(Object value) {
        for (AppsCloudMachineEventKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AppsCloudMachineEventKind value " + value, null);
    }
}

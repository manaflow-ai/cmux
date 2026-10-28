// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum SetStreamPriorityRequestPriority implements WireEnum {
    FOCUSED("focused"),
    VISIBLE("visible"),
    HIDDEN("hidden");

    private final Object wireValue;

    SetStreamPriorityRequestPriority(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SetStreamPriorityRequestPriority fromWire(Object value) {
        for (SetStreamPriorityRequestPriority candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown SetStreamPriorityRequestPriority value " + value, null);
    }
}
